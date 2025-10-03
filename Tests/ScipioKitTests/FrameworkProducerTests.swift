import Foundation
import Testing
@testable @_spi(Internals) import ScipioKit
import ScipioStorage
import Logging

struct FrameworkProducerTests {
    
    init() {
        LoggingSystem.bootstrap { _ in SwiftLogNoOpLogHandler() }
    }
    
    @Test func cacheSharing() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let outputDir = tempDir.appendingPathComponent("test-output-\(UUID().uuidString)")
        
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        
        defer {
            try? FileManager.default.removeItem(at: outputDir)
        }
        
        // Create mock cache storages
        let consumerStorage = MockCacheStorage(name: "consumer")
        let producer1Storage = MockCacheStorage(name: "producer1")
        let producer2Storage = MockCacheStorage(name: "producer2")
        
        // Create cache policies
        let consumerPolicy = Runner.Options.CachePolicy(
            storage: consumerStorage,
            actors: [.consumer]
        )
        let producerPolicy1 = Runner.Options.CachePolicy(
            storage: producer1Storage,
            actors: [.producer]
        )
        let producerPolicy2 = Runner.Options.CachePolicy(
            storage: producer2Storage,
            actors: [.producer]
        )
        
        let cachePolicies = [consumerPolicy, producerPolicy1, producerPolicy2]
        
        // Use CacheKeyTests/AsRemotePackage fixture to avoid revision detection issues
        let testPackagePath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("CacheKeyTests")
            .appendingPathComponent("AsRemotePackage")
        
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
        
        let restoredTargets: Set<CacheSystem.CacheTarget> = [mockTarget]
        let mockCacheKey = try await cacheSystem.calculateCacheKey(of: mockTarget)
        
        // Setup initial state: producer1 has cache, producer2 doesn't
        try await producer1Storage.setHasCache(for: mockCacheKey, value: true)
        try await producer2Storage.setHasCache(for: mockCacheKey, value: false)
        
        // Test FrameworkProducer's cache sharing functionality
        await frameworkProducer.shareRestoredCachesToProducers(restoredTargets, cacheSystem: cacheSystem)
        
        let producer1CacheCalls = await producer1Storage.getCacheFrameworkCalls()
        let producer2CacheCalls = await producer2Storage.getCacheFrameworkCalls()
        
        // Verify behavior: producer1 already has cache so no call, producer2 doesn't have cache so gets a call
        #expect(producer1CacheCalls.count == 0, "Producer1 already has cache, so cacheFramework should not be called")
        try #require(producer2CacheCalls.count == 1, "Producer2 doesn't have cache, so cacheFramework should be called once")
        
        // Verify the cache call was made with correct parameters
        let actualFrameworkPath = producer2CacheCalls[0].frameworkPath
        let expectedFrameworkPath = outputDir.appendingPathComponent(buildProduct.frameworkName)
        #expect(actualFrameworkPath == expectedFrameworkPath, "Framework path should match")
        
        // Verify the cache call was made with the correct cache key
        let expectedCacheKey = try mockCacheKey.calculateChecksum()
        #expect(producer2CacheCalls[0].cacheKey == expectedCacheKey, "Cache key should match the actual cache key used")
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

private actor MockCacheStorage: CacheStorage {
    let displayName: String
    let parallelNumber: Int? = 1
    
    private var hasCacheMap: [String: Bool] = [:]
    private var cacheFrameworkCalls: [(frameworkPath: URL, cacheKey: String)] = []
    
    init(name: String) {
        self.displayName = name
    }
    
    func existsValidCache(for cacheKey: some CacheKey) async throws -> Bool {
        let keyString = try cacheKey.calculateChecksum()
        return hasCacheMap[keyString] ?? false
    }
    
    func fetchArtifacts(for cacheKey: some CacheKey, to destinationDir: URL) async throws {
        // Mock implementation - no-op
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
    
    func getCacheFrameworkCalls() -> [(frameworkPath: URL, cacheKey: String)] {
        return cacheFrameworkCalls
    }
}