import CacheStorage
import Darwin
import Foundation
import Testing
import os
@testable import ScipioKit

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
        let cacheKey = ConcurrencyTestCacheKey(targetName: "Example")

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
        let cacheKey = ConcurrencyTestCacheKey(targetName: "Example")
        let stagingPath = baseURL.appending(components: "Scipio", "Example", try cacheKey.calculateChecksum(), ".abandoned-Example.xcframework")
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
        let cacheKey = ConcurrencyTestCacheKey(targetName: "Example")

        await firstStorage.cacheFramework(firstFramework, for: cacheKey)
        #expect(await !secondStorage.existsValidCache(for: cacheKey))
        let cacheDirectory = baseURL.appending(components: "Scipio", "Example", try cacheKey.calculateChecksum())
        #expect(try LocalFileSystem.default.getDirectoryContents(cacheDirectory).isEmpty)

        await secondStorage.cacheFramework(secondFramework, for: cacheKey)
        #expect(await secondStorage.existsValidCache(for: cacheKey))
        try await expectRestoredFramework(from: secondStorage, cacheKey: cacheKey, in: baseURL)
        try expectOnlyPublishedFramework(in: baseURL, cacheKey: cacheKey)
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
        let cacheKey = ConcurrencyTestCacheKey(targetName: "Example")

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
    let framework = baseURL.appending(components: worktree, "Example.xcframework")
    try LocalFileSystem.default.writeFileContents(framework.appending(component: "Info.plist"), data: contents)
    try LocalFileSystem.default.writeFileContents(framework.appending(components: "Example.framework", "Example"), data: contents)
    return framework
}

private func expectOnlyPublishedFramework(in baseURL: URL, cacheKey: ConcurrencyTestCacheKey) throws {
    let cacheDirectory = baseURL.appending(components: "Scipio", "Example", try cacheKey.calculateChecksum())
    #expect(try LocalFileSystem.default.getDirectoryContents(cacheDirectory) == ["Example.xcframework"])
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
    let contents = try fileSystem.readFileContents(restored.appending(components: "Example.xcframework", "Info.plist"))
    #expect(contents == expectedContents)
    let payload = try fileSystem.readFileContents(restored.appending(components: "Example.xcframework", "Example.framework", "Example"))
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
    let framework: URL
    var copyGate: CopyGate?
    var failAfterPartialCopy = false

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
        guard source == framework else {
            try base.copy(from: source, to: destination)
            return
        }
        try base.createDirectory(destination, recursive: false)
        try base.copy(
            from: source.appending(component: "Info.plist"),
            to: destination.appending(component: "Info.plist")
        )
        if let copyGate, !copyGate.pause() {
            throw CopyFailed()
        }
        if failAfterPartialCopy { throw CopyFailed() }
        try base.createDirectory(destination.appending(component: "Example.framework"), recursive: false)
        try base.copy(
            from: source.appending(components: "Example.framework", "Example"),
            to: destination.appending(components: "Example.framework", "Example")
        )
    }

    private struct CopyFailed: Error {}
}
