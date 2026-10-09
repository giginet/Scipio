import Foundation
import Testing
@testable @_spi(Internals) import ScipioKit
import CacheStorage
import Logging
import os

struct FrameworkProducerTests {
    init() async {
        await LoggingTestHelper.shared.bootstrap()
    }

    @Test func cacheSharing() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let outputDir = tempDir.appending(component: "test-output-\(UUID().uuidString)")

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: outputDir)
        }

        // Create mock cache storages
        let restoreSourceStorage = MockCacheStorage(name: "RestoreSource")
        let alreadyHasCacheStorage = MockCacheStorage(name: "AlreadyHasCache")
        let needsSharedCacheStorage = MockCacheStorage(name: "NeedsSharedCache")

        // Create cache policies
        let restoreSourcePolicy = Runner.Options.FrameworkCachePolicy(
            storage: restoreSourceStorage,
            actors: [.consumer, .producer]  // Will restore and should be excluded from sharing
        )
        let alreadyHasCachePolicy = Runner.Options.FrameworkCachePolicy(
            storage: alreadyHasCacheStorage,
            actors: [.producer]  // Already has cache, won't be shared
        )
        let needsSharedCachePolicy = Runner.Options.FrameworkCachePolicy(
            storage: needsSharedCacheStorage,
            actors: [.producer]  // No cache, should receive share
        )

        let cachePolicies = [restoreSourcePolicy, alreadyHasCachePolicy, needsSharedCachePolicy]

        // Use the CacheKeyTests/AsRemotePackage fixture here because it simulates a remote package with a fixed revision.
        let testPackagePath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .appending(components: "Resources", "Fixtures", "CacheKeyTests", "AsRemotePackage")

        let descriptionPackage = try await DescriptionPackage(
            packageDirectory: testPackagePath,
            mode: .prepareDependencies,
            resolvedPackagesCachePolicies: [],
            onlyUseVersionsFromResolvedFile: false
        )

        let frameworkProducer = FrameworkProducer(
            descriptionPackage: descriptionPackage,
            buildOptions: BuildOptions(
                buildConfiguration: .debug,
                isDebugSymbolsEmbedded: false,
                frameworkType: .dynamic,
                sdks: [.iOS],
                extraFlags: nil,
                extraBuildParameters: nil,
                enableLibraryEvolution: false,
                keepPublicHeadersStructure: false,
                customFrameworkModuleMapContents: nil,
                stripStaticDWARFSymbols: false
            ),
            buildOptionsMatrix: [:],
            cachePolicies: cachePolicies,
            overwrite: false,
            outputDir: outputDir
        )

        let cacheSystem = CacheSystem(outputDirectory: outputDir)

        // Create a mock cache target using the real package info
        let package = try #require(
            descriptionPackage
                .graph
                .allPackages
                .values
                .first { $0.name == "scipio-testing" }
        )
        let target = try #require(package.targets.first { $0.name == "ScipioTesting" })
        let buildProduct = BuildProduct(package: package, target: target)
        let mockTarget = CacheSystem.CacheTarget(
            buildProduct: buildProduct,
            buildOptions: BuildOptions(
                buildConfiguration: .debug,
                isDebugSymbolsEmbedded: false,
                frameworkType: .dynamic,
                sdks: [.iOS],
                extraFlags: nil,
                extraBuildParameters: nil,
                enableLibraryEvolution: false,
                keepPublicHeadersStructure: false,
                customFrameworkModuleMapContents: nil,
                stripStaticDWARFSymbols: false
            )
        )

        let targetGraph = try DependencyGraph.resolve(
            Set([mockTarget]),
            id: \.buildProduct.target.name,
            childIDs: { _ in [] }
        )
        let cacheKeys = try await cacheSystem.calculateCacheKeys(for: targetGraph)
        let mockCacheKey = try #require(cacheKeys[mockTarget])

        // Setup initial state: 
        // - RestoreSource: has cache and will be the restore source (should be excluded from sharing)
        // - AlreadyHasCache: has cache and should not receive share 
        // - NeedsSharedCache: no cache and should receive shared cache
        try await restoreSourceStorage.setHasCache(for: mockCacheKey, value: true)
        try await alreadyHasCacheStorage.setHasCache(for: mockCacheKey, value: true)
        try await needsSharedCacheStorage.setHasCache(for: mockCacheKey, value: false)

        // Test FrameworkProducer's cache sharing functionality
        try await frameworkProducer.produce()

        // Get restoration calls (fetch operations)
        let restoreSourceFetchCalls = await restoreSourceStorage.getFetchArtifactsCalls()
        let alreadyHasFetchCalls = await alreadyHasCacheStorage.getFetchArtifactsCalls()
        let needsSharedFetchCalls = await needsSharedCacheStorage.getFetchArtifactsCalls()

        // Get cache sharing calls (cache operations)
        let restoreSourceCacheCalls = await restoreSourceStorage.getCacheFrameworkCalls()
        let alreadyHasCacheCalls = await alreadyHasCacheStorage.getCacheFrameworkCalls()
        let needsSharedCacheCalls = await needsSharedCacheStorage.getCacheFrameworkCalls()

        // Verify restoration behavior:
        // - RestoreSource should be used for restoration (has cache and is consumer)
        #expect(restoreSourceFetchCalls.count == 1, "RestoreSource storage should be used for restoration")
        #expect(alreadyHasFetchCalls.count == 0, "AlreadyHasCache has cache but restoreSource is tried first")
        #expect(needsSharedFetchCalls.count == 0, "NeedsSharedCache has no cache, so not used for restoration")

        // Verify cache sharing behavior:
        // - RestoreSource was the restore source, so it should be excluded from sharing
        // - AlreadyHasCache already has cache, so it should not receive share
        // - NeedsSharedCache doesn't have cache and should receive shared cache
        #expect(restoreSourceCacheCalls.count == 0, "RestoreSource was the restore source, so it should be excluded from sharing")
        #expect(alreadyHasCacheCalls.count == 0, "AlreadyHasCache already has cache, so cacheFramework should not be called")
        try #require(needsSharedCacheCalls.count == 1, "NeedsSharedCache doesn't have cache, so cacheFramework should be called once")

        // Verify the cache call was made with correct parameters
        let actualFrameworkPath = needsSharedCacheCalls[0].frameworkPath
        let expectedFrameworkPath = outputDir.appending(component: buildProduct.frameworkName)
        #expect(actualFrameworkPath == expectedFrameworkPath, "Framework path should match")

        // Verify the cache call was made with the correct cache key
        let expectedCacheKey = try mockCacheKey.calculateChecksum()
        #expect(needsSharedCacheCalls[0].cacheKey == expectedCacheKey, "Cache key should match the actual cache key used")
    }

    @Test(
        "Local cache rechecks restore late entries and build after misses or fetch errors",
        .serialized,
        .temporaryDirectory,
        arguments: LateCacheState.allCases
    )
    private func localCacheIsRecheckedBeforeBuild(cacheState: LateCacheState) async throws {
        let baseURL = TemporaryDirectory.url
        let outputDir = baseURL.appending(component: "output")
        try LocalFileSystem.default.createDirectory(outputDir, recursive: true)
        let packagePath = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .appending(components: "Resources", "Fixtures", "UsingBinaryPackage")
        let descriptionPackage = try await DescriptionPackage(
            packageDirectory: packagePath,
            mode: .prepareDependencies,
            resolvedPackagesCachePolicies: [],
            onlyUseVersionsFromResolvedFile: true
        )
        let buildOptions = BuildOptions(
            buildConfiguration: .debug,
            isDebugSymbolsEmbedded: false,
            frameworkType: .dynamic,
            sdks: [.iOS],
            extraFlags: nil,
            extraBuildParameters: nil,
            enableLibraryEvolution: false,
            keepPublicHeadersStructure: false,
            customFrameworkModuleMapContents: nil,
            stripStaticDWARFSymbols: false
        )
        let graph = try descriptionPackage.resolveBuildProductDependencyGraph().map {
            CacheSystem.CacheTarget(buildProduct: $0, buildOptions: buildOptions)
        }
        let target = try #require(graph.allNodes.map(\.value).first { $0.buildProduct.target.name == "SomeBinary" })
        guard case let .binary(binaryLocation) = target.buildProduct.target.resolvedModuleType else {
            Issue.record("The fixture must contain a binary target.")
            return
        }
        let cacheSystem = CacheSystem(outputDirectory: outputDir)
        let cacheKeys = try await cacheSystem.calculateCacheKeys(for: graph)
        let cacheKey = try #require(cacheKeys[target])
        let cacheEntry = baseURL
            .appendingPathComponent("Scipio")
            .appendingPathComponent("SomeBinary")
            .appendingPathComponent(try cacheKey.calculateChecksum())
            .appendingPathComponent("SomeBinary.xcframework", isDirectory: true)
        let cachedFramework = baseURL.appending(components: "source", "SomeBinary.xcframework")
        let marker = Data("published by another worktree".utf8)
        try LocalFileSystem.default.writeFileContents(cachedFramework.appending(component: "Info.plist"), data: marker)
        let buildSource = baseURL.appending(components: "build-source", "SomeBinary.xcframework")
        let builtMarker = Data("built by this worktree".utf8)
        try LocalFileSystem.default.writeFileContents(buildSource.appending(component: "Info.plist"), data: builtMarker)

        let publisher = LocalDiskCacheStorage(baseURL: baseURL)
        if cacheState != .missing {
            await publisher.cacheFramework(cachedFramework, for: cacheKey)
            try #require(await publisher.existsValidCache(for: cacheKey))
        }

        let fileSystem = LateCacheFileSystem(
            cacheEntry: cacheEntry,
            binaryArtifact: binaryLocation.artifactURL(rootPackageDirectory: packagePath),
            buildSource: buildSource,
            cacheState: cacheState
        )
        let consumer = LocalDiskCacheStorage(baseURL: baseURL, fileSystem: fileSystem)
        let sharingStorage = MockCacheStorage(name: "LateSharedCache")
        let remoteStorage = MockCacheStorage(name: "RemoteCache")
        let producer = FrameworkProducer(
            descriptionPackage: descriptionPackage,
            buildOptions: buildOptions,
            buildOptionsMatrix: [:],
            cachePolicies: [
                .init(storage: remoteStorage, actors: [.consumer]),
                .init(storage: consumer, actors: [.consumer, .producer]),
                .init(storage: sharingStorage, actors: [.producer]),
            ],
            overwrite: false,
            outputDir: outputDir,
            fileSystem: fileSystem
        )

        try await producer.produce()

        #expect(fileSystem.cacheEntryCheckCount == 2)
        let shouldRestore = cacheState == .available
        #expect(fileSystem.buildCopyCount == (shouldRestore ? 0 : 1))
        let restoredContents = try LocalFileSystem.default.readFileContents(
            outputDir.appending(components: "SomeBinary.xcframework", "Info.plist")
        )
        #expect(restoredContents == (shouldRestore ? marker : builtMarker))
        #expect(await cacheSystem.existsValidCache(cacheKey: cacheKey))
        let checksum = try cacheKey.calculateChecksum()
        #expect(await remoteStorage.getCacheCheckCalls() == [checksum])
        let shared = await sharingStorage.getCacheFrameworkCalls()
        try #require(shared.count == 1)
        #expect(shared[0].cacheKey == checksum)
    }

    @Test(
        "Each completed target is cached before the next build, including when that build fails",
        .temporaryDirectory,
        arguments: [false, true]
    )
    private func completedTargetsArePublishedBeforeNextBuild(failNextBuild: Bool) async throws {
        let base = LocalFileSystem.default
        let root = TemporaryDirectory.url
        let packagePath = try await makeTaggedBinaryPackage()
        let package = try await DescriptionPackage(
            packageDirectory: packagePath, mode: .createPackage,
            resolvedPackagesCachePolicies: [], onlyUseVersionsFromResolvedFile: true
        )
        let options = BuildOptions(
            buildConfiguration: .debug, isDebugSymbolsEmbedded: false, frameworkType: .dynamic,
            sdks: [.iOS], extraFlags: nil, extraBuildParameters: nil, enableLibraryEvolution: false,
            keepPublicHeadersStructure: false, customFrameworkModuleMapContents: nil, stripStaticDWARFSymbols: false
        )
        let output = root.appending(component: "output")
        let cacheSystem = CacheSystem(outputDirectory: output)
        let graph = try package.resolveBuildProductDependencyGraph().map {
            CacheSystem.CacheTarget(buildProduct: $0, buildOptions: options)
        }
        let keys = try await cacheSystem.calculateCacheKeys(for: graph)
        try #require(keys.count == 2)
        var cacheEntries: [String: URL] = [:]
        for (target, key) in keys {
            let name = target.buildProduct.target.name
            cacheEntries[name] = root.appending(components: "Scipio", name, try key.calculateChecksum(), "\(name).xcframework")
        }
        let fileSystem = BinaryBuildFileSystem(output: output, cacheEntries: cacheEntries, failNextBuild: failNextBuild)
        let local = LocalDiskCacheStorage(baseURL: root, fileSystem: fileSystem)
        let deferred = MockCacheStorage(name: "DeferredCache")
        let producer = FrameworkProducer(
            descriptionPackage: package, buildOptions: options, buildOptionsMatrix: [:],
            cachePolicies: [.init(storage: deferred, actors: [.producer]), .init(storage: local, actors: [.producer])],
            overwrite: false, outputDir: output, fileSystem: fileSystem
        )
        if failNextBuild {
            await #expect(throws: BinaryBuildFileSystem.BuildFailed.self) { try await producer.produce() }
        } else {
            try await producer.produce()
        }
        #expect(fileSystem.buildCount == 2)
        #expect(fileSystem.publicationCount == (failNextBuild ? 1 : 2))
        #expect(await deferred.getCacheFrameworkCalls().count == (failNextBuild ? 1 : 2))
        for key in keys.values {
            let isPublished = await local.existsValidCache(for: key)
            #expect(isPublished == base.exists(output.appending(component: "\(key.targetName).xcframework")))
        }
    }

    private func makeTaggedBinaryPackage() async throws -> URL {
        let base = LocalFileSystem.default
        let packagePath = TemporaryDirectory.url.appending(component: "package")
        let fixture = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(components: "Resources", "Fixtures", "BinaryPackage", "SomeBinary.zip")
        try base.createDirectory(packagePath, recursive: true)
        for name in ["First", "Second"] {
            try base.copy(from: fixture, to: packagePath.appending(component: "\(name).zip"))
        }
        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "TwoBinaries",
            platforms: [.iOS(.v13)],
            products: [.library(name: "TwoBinaries", targets: ["First", "Second"])],
            targets: [
                .binaryTarget(name: "First", path: "First.zip"),
                .binaryTarget(name: "Second", path: "Second.zip"),
            ]
        )
        """
        try base.writeFileContents(packagePath.appending(component: "Package.swift"), data: Data(manifest.utf8))
        let executor = ProcessExecutor()
        let git = ["/usr/bin/xcrun", "git", "-C", packagePath.path(percentEncoded: false)]
        try await executor.execute(git + ["init"])
        try await executor.execute(git + ["add", "."])
        try await executor.execute(git + [
            "-c", "user.name=Scipio Tests",
            "-c", "user.email=scipio@example.com",
            "commit", "-m", "Initial commit",
        ])
        try await executor.execute(git + ["tag", "v1.0.0"])
        return packagePath
    }

}

// MARK: - Mock Classes

private struct MockCacheKey: CacheKey {
    let targetName: String

    func calculateChecksum() throws -> String {
        return "mock-checksum-\(targetName)"
    }
}

// MARK: - Mock Cache Storage

private actor MockCacheStorage: FrameworkCacheStorage {
    let displayName: String
    let parallelNumber: Int? = 1

    private var hasCacheMap: [String: Bool] = [:]
    private var cacheCheckCalls: [String] = []
    private var fetchArtifactsCalls: [(cacheKey: String, destinationDir: URL)] = []
    private var cacheFrameworkCalls: [(frameworkPath: URL, cacheKey: String)] = []

    init(name: String) {
        self.displayName = name
    }

    func existsValidCache(for cacheKey: some CacheKey) async throws -> Bool {
        let keyString = try cacheKey.calculateChecksum()
        cacheCheckCalls.append(keyString)
        return hasCacheMap[keyString] ?? false
    }

    func fetchArtifacts(for cacheKey: some CacheKey, to destinationDir: URL) async throws {
        let keyString = try cacheKey.calculateChecksum()
        let call = (cacheKey: keyString, destinationDir: destinationDir)
        fetchArtifactsCalls.append(call)
    }

    func cacheFramework(_ frameworkPath: URL, for cacheKey: some CacheKey) async throws {
        let keyString = try cacheKey.calculateChecksum()
        let call = (frameworkPath: frameworkPath, cacheKey: keyString)
        cacheFrameworkCalls.append(call)
    }

    // Test helper methods
    func setHasCache(for cacheKey: some CacheKey, value: Bool) async throws {
        let keyString = try cacheKey.calculateChecksum()
        hasCacheMap[keyString] = value
    }

    func getFetchArtifactsCalls() -> [(cacheKey: String, destinationDir: URL)] {
        return fetchArtifactsCalls
    }

    func getCacheCheckCalls() -> [String] {
        cacheCheckCalls
    }

    func getCacheFrameworkCalls() -> [(frameworkPath: URL, cacheKey: String)] {
        return cacheFrameworkCalls
    }
}

private enum LateCacheState: CaseIterable, Sendable {
    case available
    case missing
    case unreadable
}

private struct LateCacheFileSystem: FileSystem {
    private struct State {
        var cacheChecks = 0
        var buildCopies = 0
    }

    private let base = LocalFileSystem.default
    let cacheEntry: URL
    let binaryArtifact: URL
    let buildSource: URL
    let cacheState: LateCacheState
    private let state = OSAllocatedUnfairLock(initialState: State())

    var cacheEntryCheckCount: Int { state.withLock { $0.cacheChecks } }
    var buildCopyCount: Int { state.withLock { $0.buildCopies } }
    var tempDirectory: URL { base.tempDirectory }
    var cachesDirectory: URL? { base.cachesDirectory }
    var currentWorkingDirectory: URL? { base.currentWorkingDirectory }

    func writeFileContents(_ path: URL, data: Data) throws { try base.writeFileContents(path, data: data) }
    func readFileContents(_ path: URL) throws -> Data { try base.readFileContents(path) }
    func exists(_ path: URL, followSymlink: Bool) -> Bool {
        // Hide the entry from the initial scan; later checks use the real file system.
        if isCacheEntry(path), state.withLock({ state in state.cacheChecks += 1; return state.cacheChecks == 1 }) {
            return false
        }
        return base.exists(path, followSymlink: followSymlink)
    }
    func isDirectory(_ path: URL) -> Bool { base.isDirectory(path) }
    func isFile(_ path: URL) -> Bool { base.isFile(path) }
    func isSymlink(_ path: URL) -> Bool { base.isSymlink(path) }
    func copy(from source: URL, to destination: URL) throws {
        if isCacheEntry(source), cacheState == .unreadable {
            throw FetchFailed()
        }
        if source == binaryArtifact {
            state.withLock { $0.buildCopies += 1 }
            try base.copy(from: buildSource, to: destination)
        } else {
            try base.copy(from: source, to: destination)
        }
    }
    func createDirectory(_ path: URL, recursive: Bool) throws { try base.createDirectory(path, recursive: recursive) }
    func move(from source: URL, to destination: URL) throws { try base.move(from: source, to: destination) }
    func getDirectoryContents(_ path: URL) throws -> [String] { try base.getDirectoryContents(path) }
    func removeFileTree(_ path: URL) throws { try base.removeFileTree(path) }

    private func isCacheEntry(_ path: URL) -> Bool {
        path.path(percentEncoded: false).split(separator: "/") == cacheEntry.path(percentEncoded: false).split(separator: "/")
    }

    private struct FetchFailed: Error {}
}

private struct BinaryBuildFileSystem: FileSystem {
    private let base = LocalFileSystem.default
    let output: URL
    let cacheEntries: [String: URL]
    let failNextBuild: Bool
    private let completedTargets = OSAllocatedUnfairLock(initialState: [String]())
    private let publications = OSAllocatedUnfairLock(initialState: 0)
    var publicationCount: Int { publications.withLock { $0 } }
    var buildCount: Int { completedTargets.withLock { $0.count } }
    var tempDirectory: URL { base.tempDirectory }
    var cachesDirectory: URL? { base.cachesDirectory }
    var currentWorkingDirectory: URL? { base.currentWorkingDirectory }

    func copy(from source: URL, to destination: URL) throws {
        let name = destination.deletingPathExtension().lastPathComponent
        guard destination.deletingLastPathComponent().path(percentEncoded: false).split(separator: "/")
            == output.path(percentEncoded: false).split(separator: "/"), cacheEntries[name] != nil else {
            try base.copy(from: source, to: destination)
            return
        }
        let previous = completedTargets.withLock { targets in
            let previous = targets.last
            targets.append(name)
            return previous
        }
        if let previous {
            let entry = try #require(cacheEntries[previous])
            #expect(base.exists(entry))
            if base.exists(entry) {
                #expect(try base.readFileContents(entry.appending(component: "Info.plist")) == Data(previous.utf8))
            }
            if failNextBuild { throw BuildFailed() }
        }
        try base.writeFileContents(output.appending(components: "\(name).xcframework", "Info.plist"), data: Data(name.utf8))
    }
    func writeFileContents(_ path: URL, data: Data) throws { try base.writeFileContents(path, data: data) }
    func readFileContents(_ path: URL) throws -> Data { try base.readFileContents(path) }
    func exists(_ path: URL, followSymlink: Bool) -> Bool { base.exists(path, followSymlink: followSymlink) }
    func isDirectory(_ path: URL) -> Bool { base.isDirectory(path) }
    func isFile(_ path: URL) -> Bool { base.isFile(path) }
    func isSymlink(_ path: URL) -> Bool { base.isSymlink(path) }
    func createDirectory(_ path: URL, recursive: Bool) throws { try base.createDirectory(path, recursive: recursive) }
    func move(from source: URL, to destination: URL) throws {
        try base.move(from: source, to: destination)
        publications.withLock { $0 += 1 }
    }
    func getDirectoryContents(_ path: URL) throws -> [String] { try base.getDirectoryContents(path) }
    func removeFileTree(_ path: URL) throws { try base.removeFileTree(path) }

    struct BuildFailed: Error {}
}
