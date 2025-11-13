import Foundation
import Testing
@testable @_spi(Internals) import ScipioKit
import CacheStorage
import Logging

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
        let restoreSourcePolicy = Runner.Options.CachePolicy(
            storage: restoreSourceStorage,
            actors: [.consumer, .producer]  // Will restore and should be excluded from sharing
        )
        let alreadyHasCachePolicy = Runner.Options.CachePolicy(
            storage: alreadyHasCacheStorage,
            actors: [.producer]  // Already has cache, won't be shared
        )
        let needsSharedCachePolicy = Runner.Options.CachePolicy(
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

        let mockCacheKey = try await cacheSystem.calculateCacheKey(of: mockTarget)

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
    private var fetchArtifactsCalls: [(cacheKey: String, destinationDir: URL)] = []
    private var cacheFrameworkCalls: [(frameworkPath: URL, cacheKey: String)] = []

    init(name: String) {
        self.displayName = name
    }

    func existsValidCache(for cacheKey: some CacheKey) async throws -> Bool {
        let keyString = try cacheKey.calculateChecksum()
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

    func getCacheFrameworkCalls() -> [(frameworkPath: URL, cacheKey: String)] {
        return cacheFrameworkCalls
    }
}
