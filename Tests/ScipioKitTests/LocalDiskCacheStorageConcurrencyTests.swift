import CacheStorage
import Darwin
import Foundation
import Testing
import os
@testable import ScipioKit

private let frameworkName = "Example"
private let xcFrameworkFileName = "\(frameworkName).xcframework"
private let frameworkBundleName = "\(frameworkName).framework"
private let frameworkContents = Data("complete framework".utf8)

struct LocalDiskCacheStorageConcurrencyTests {
    @Test("A concurrent reader cannot observe an incomplete framework cache", .temporaryDirectory)
    func incompleteFrameworkIsNotPublished() async throws {
        let baseURL = TemporaryDirectory.url
        let framework = try makeFramework(in: baseURL, worktree: "output")
        let copyGate = CopyGate()
        let controlledFileSystem = ControlledFrameworkFileSystem(framework: framework, copyGate: copyGate)
        let storage = LocalDiskCacheStorage(baseURL: baseURL, fileSystem: controlledFileSystem)
        let readerStorage = LocalDiskCacheStorage(baseURL: baseURL)
        let cacheKey = ConcurrencyTestCacheKey(targetName: frameworkName)

        async let writer: Void = storage.cacheFramework(framework, for: cacheKey)
        let didPause = await copyGate.waitUntilPaused()
        if didPause {
            #expect(await !readerStorage.existsValidCache(for: cacheKey))
        }
        copyGate.resume()
        await writer

        #expect(didPause)
        #expect(await readerStorage.existsValidCache(for: cacheKey))
        try await expectRestoredFramework(from: readerStorage, cacheKey: cacheKey, in: baseURL)
    }

    @Test("Abandoned staging paths are ignored and do not block publication", .temporaryDirectory)
    func abandonedStagingDoesNotBlockPublication() async throws {
        let baseURL = TemporaryDirectory.url
        let framework = try makeFramework(in: baseURL, worktree: "output")
        let storage = LocalDiskCacheStorage(baseURL: baseURL)
        let cacheKey = ConcurrencyTestCacheKey(targetName: frameworkName)
        let stagingPath = try cacheDirectory(in: baseURL, cacheKey: cacheKey)
            .appending(component: ".abandoned-\(xcFrameworkFileName)")
        try LocalFileSystem.default.writeFileContents(stagingPath.appending(component: "Info.plist"), data: Data("partial".utf8))

        #expect(await !storage.existsValidCache(for: cacheKey))
        await storage.cacheFramework(framework, for: cacheKey)

        #expect(await storage.existsValidCache(for: cacheKey))
        #expect(LocalFileSystem.default.exists(stagingPath))
        try await expectRestoredFramework(from: storage, cacheKey: cacheKey, in: baseURL)
    }

    @Test("A failed copy leaves no published cache and allows a retry", .temporaryDirectory)
    func failedCopyDoesNotBlockRetry() async throws {
        let baseURL = TemporaryDirectory.url
        let firstFramework = try makeFramework(in: baseURL, worktree: "worktree-a")
        let secondFramework = try makeFramework(in: baseURL, worktree: "worktree-b")
        let failedFileSystem = ControlledFrameworkFileSystem(
            framework: firstFramework,
            failAfterPartialCopy: true
        )
        let firstStorage = LocalDiskCacheStorage(baseURL: baseURL, fileSystem: failedFileSystem)
        let secondStorage = LocalDiskCacheStorage(baseURL: baseURL)
        let cacheKey = ConcurrencyTestCacheKey(targetName: frameworkName)

        await firstStorage.cacheFramework(firstFramework, for: cacheKey)
        #expect(await !secondStorage.existsValidCache(for: cacheKey))
        let directory = try cacheDirectory(in: baseURL, cacheKey: cacheKey)
        #expect(try LocalFileSystem.default.getDirectoryContents(directory).isEmpty)

        await secondStorage.cacheFramework(secondFramework, for: cacheKey)
        #expect(await secondStorage.existsValidCache(for: cacheKey))
        try await expectRestoredFramework(from: secondStorage, cacheKey: cacheKey, in: baseURL)
        try expectOnlyPublishedFramework(in: baseURL, cacheKey: cacheKey)
    }

    @Test("A failed restore removes partial files and allows a retry", .temporaryDirectory)
    func failedRestoreDoesNotBlockRetry() async throws {
        let baseURL = TemporaryDirectory.url
        let framework = try makeFramework(in: baseURL, worktree: "output")
        let cacheKey = ConcurrencyTestCacheKey(targetName: frameworkName)
        let storage = LocalDiskCacheStorage(baseURL: baseURL)
        await storage.cacheFramework(framework, for: cacheKey)
        try #require(await storage.existsValidCache(for: cacheKey))
        let cacheEntry = try cacheDirectory(in: baseURL, cacheKey: cacheKey).appending(component: xcFrameworkFileName)
        let failedStorage = LocalDiskCacheStorage(
            baseURL: baseURL,
            fileSystem: ControlledFrameworkFileSystem(framework: cacheEntry, failAfterPartialCopy: true)
        )
        let output = baseURL.appending(component: "restored")
        try LocalFileSystem.default.createDirectory(output, recursive: true)

        await #expect(throws: ControlledFrameworkFileSystem.CopyFailed.self) {
            try await failedStorage.fetchArtifacts(for: cacheKey, to: output)
        }
        #expect(try LocalFileSystem.default.getDirectoryContents(output).isEmpty)

        try await expectRestoredFramework(from: storage, cacheKey: cacheKey, in: baseURL)
        #expect(try LocalFileSystem.default.getDirectoryContents(output) == [xcFrameworkFileName])
    }

    @Test("An existing cache entry skips the framework copy", .temporaryDirectory)
    func existingCacheSkipsCopy() async throws {
        let baseURL = TemporaryDirectory.url
        let framework = try makeFramework(in: baseURL, worktree: "output")
        let cacheKey = ConcurrencyTestCacheKey(targetName: frameworkName)
        let storage = LocalDiskCacheStorage(baseURL: baseURL)
        await storage.cacheFramework(framework, for: cacheKey)
        try #require(await storage.existsValidCache(for: cacheKey))
        let fileSystem = ControlledFrameworkFileSystem(framework: framework)
        let writer = LocalDiskCacheStorage(baseURL: baseURL, fileSystem: fileSystem)

        await writer.cacheFramework(framework, for: cacheKey)

        #expect(fileSystem.copyCount == 0)
        try expectOnlyPublishedFramework(in: baseURL, cacheKey: cacheKey)
        try await expectRestoredFramework(from: storage, cacheKey: cacheKey, in: baseURL)
    }

    @Test("A restore does not overwrite an existing framework", .temporaryDirectory)
    func restorePreservesExistingFramework() async throws {
        let baseURL = TemporaryDirectory.url
        let framework = try makeFramework(in: baseURL, worktree: "output")
        let cacheKey = ConcurrencyTestCacheKey(targetName: frameworkName)
        let storage = LocalDiskCacheStorage(baseURL: baseURL)
        await storage.cacheFramework(framework, for: cacheKey)
        try #require(await storage.existsValidCache(for: cacheKey))
        let existingContents = Data("existing framework".utf8)
        let existingFramework = try makeFramework(in: baseURL, worktree: "restored", contents: existingContents)
        let output = existingFramework.deletingLastPathComponent()
        let cacheEntry = try cacheDirectory(in: baseURL, cacheKey: cacheKey).appending(component: xcFrameworkFileName)
        let fileSystem = ControlledFrameworkFileSystem(framework: cacheEntry)
        let reader = LocalDiskCacheStorage(baseURL: baseURL, fileSystem: fileSystem)

        await #expect(throws: FileSystemError.self) {
            try await reader.fetchArtifacts(for: cacheKey, to: output)
        }
        #expect(fileSystem.copyCount == 0)
        #expect(try LocalFileSystem.default.getDirectoryContents(output) == [xcFrameworkFileName])
        #expect(try LocalFileSystem.default.readFileContents(existingFramework.appending(component: "Info.plist")) == existingContents)
        let payload = existingFramework.appending(components: frameworkBundleName, frameworkName)
        #expect(try LocalFileSystem.default.readFileContents(payload) == existingContents)
    }

    @Test("Overlapping writers keep the first complete cache and remove staging paths", .temporaryDirectory)
    func concurrentWritersPublishOneFramework() async throws {
        let baseURL = TemporaryDirectory.url
        let firstContents = Data("first writer".utf8)
        let secondContents = Data("second writer".utf8)
        let firstFramework = try makeFramework(in: baseURL, worktree: "worktree-a", contents: firstContents)
        let secondFramework = try makeFramework(in: baseURL, worktree: "worktree-b", contents: secondContents)
        let firstGate = CopyGate()
        let firstStorage = LocalDiskCacheStorage(
            baseURL: baseURL,
            fileSystem: ControlledFrameworkFileSystem(framework: firstFramework, copyGate: firstGate)
        )
        let secondStorage = LocalDiskCacheStorage(baseURL: baseURL)
        let cacheKey = ConcurrencyTestCacheKey(targetName: frameworkName)

        async let firstWriter: Void = firstStorage.cacheFramework(firstFramework, for: cacheKey)
        let firstDidPause = await firstGate.waitUntilPaused()
        #expect(await !firstStorage.existsValidCache(for: cacheKey))

        await secondStorage.cacheFramework(secondFramework, for: cacheKey)
        #expect(await secondStorage.existsValidCache(for: cacheKey))
        firstGate.resume()
        await firstWriter

        #expect(firstDidPause)
        try expectOnlyPublishedFramework(in: baseURL, cacheKey: cacheKey)
        try await expectRestoredFramework(from: secondStorage, cacheKey: cacheKey, in: baseURL, contents: secondContents)
    }
}

private func makeFramework(in baseURL: URL, worktree: String, contents: Data = frameworkContents) throws -> URL {
    let framework = baseURL.appending(components: worktree, xcFrameworkFileName)
    try LocalFileSystem.default.writeFileContents(framework.appending(component: "Info.plist"), data: contents)
    try LocalFileSystem.default.writeFileContents(framework.appending(components: frameworkBundleName, frameworkName), data: contents)
    return framework
}

private func expectOnlyPublishedFramework(in baseURL: URL, cacheKey: ConcurrencyTestCacheKey) throws {
    let directory = try cacheDirectory(in: baseURL, cacheKey: cacheKey)
    #expect(try LocalFileSystem.default.getDirectoryContents(directory) == [xcFrameworkFileName])
}

private func cacheDirectory(in baseURL: URL, cacheKey: ConcurrencyTestCacheKey) throws -> URL {
    baseURL.appending(components: "Scipio", cacheKey.targetName, try cacheKey.calculateChecksum())
}

private func expectRestoredFramework(
    from storage: LocalDiskCacheStorage,
    cacheKey: ConcurrencyTestCacheKey,
    in baseURL: URL,
    contents expectedContents: Data = frameworkContents
) async throws {
    let fileSystem = LocalFileSystem.default
    let restored = baseURL.appending(component: "restored")
    try fileSystem.createDirectory(restored, recursive: true)
    try await storage.fetchArtifacts(for: cacheKey, to: restored)
    let contents = try fileSystem.readFileContents(restored.appending(components: xcFrameworkFileName, "Info.plist"))
    #expect(contents == expectedContents)
    let payload = try fileSystem.readFileContents(restored.appending(components: xcFrameworkFileName, frameworkBundleName, frameworkName))
    #expect(payload == expectedContents)
}

private final class CopyGate: Sendable {
    private struct State {
        var didPause = false
        var isResumed = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func pause() -> Bool {
        // FileSystem.copy is synchronous, so this side cannot suspend with await.
        state.withLock { $0.didPause = true }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !state.withLock({ $0.isResumed }) {
            if clock.now >= deadline { return false }
            _ = sched_yield()
        }
        return true
    }

    func waitUntilPaused() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !state.withLock({ $0.didPause }) {
            if clock.now >= deadline { return false }
            do {
                try await Task.sleep(for: .milliseconds(1))
            } catch {
                return false
            }
        }
        return true
    }

    func resume() {
        state.withLock { $0.isResumed = true }
    }
}

private struct ConcurrencyTestCacheKey: CacheKey {
    let targetName: String
}

private struct ControlledFrameworkFileSystem: FileSystem {
    private let base = LocalFileSystem.default
    private let copies = OSAllocatedUnfairLock(initialState: 0)
    let framework: URL
    var copyGate: CopyGate?
    var failAfterPartialCopy = false

    var copyCount: Int { copies.withLock { $0 } }
    var tempDirectory: URL { base.tempDirectory }
    var cachesDirectory: URL? { base.cachesDirectory }
    var currentWorkingDirectory: URL? { base.currentWorkingDirectory }

    func writeFileContents(_ path: URL, data: Data) throws { try base.writeFileContents(path, data: data) }
    func readFileContents(_ path: URL) throws -> Data { try base.readFileContents(path) }
    func exists(_ path: URL, followSymlink: Bool) -> Bool { base.exists(path, followSymlink: followSymlink) }
    func isDirectory(_ path: URL) -> Bool { base.isDirectory(path) }
    func isFile(_ path: URL) -> Bool { base.isFile(path) }
    func isSymlink(_ path: URL) -> Bool { base.isSymlink(path) }
    func createDirectory(_ path: URL, recursive: Bool) throws { try base.createDirectory(path, recursive: recursive) }
    func move(from source: URL, to destination: URL) throws { try base.move(from: source, to: destination) }
    func getDirectoryContents(_ path: URL) throws -> [String] { try base.getDirectoryContents(path) }
    func removeFileTree(_ path: URL) throws { try base.removeFileTree(path) }

    func copy(from source: URL, to destination: URL) throws {
        guard source.pathComponents == framework.pathComponents else {
            try base.copy(from: source, to: destination)
            return
        }
        copies.withLock { $0 += 1 }
        try base.createDirectory(destination, recursive: false)
        try base.copy(
            from: source.appending(component: "Info.plist"),
            to: destination.appending(component: "Info.plist")
        )
        if let copyGate, !copyGate.pause() {
            throw CopyFailed()
        }
        if failAfterPartialCopy { throw CopyFailed() }
        try base.createDirectory(destination.appending(component: frameworkBundleName), recursive: false)
        try base.copy(
            from: source.appending(components: frameworkBundleName, frameworkName),
            to: destination.appending(components: frameworkBundleName, frameworkName)
        )
    }

    struct CopyFailed: Error {}
}
