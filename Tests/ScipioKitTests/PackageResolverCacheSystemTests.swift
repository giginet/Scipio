import Foundation
@testable @_spi(Internals) import ScipioKit
import ScipioKitCore
import Testing
import CacheStorage

package let packageURL = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .appending(components: "Resources", "Fixtures", "TestingPackage")
private let packageLocation = PackageLocation(packageDirectory: packageURL)
private let fileSystem: LocalFileSystem = .default

struct PackageResolverCacheSystemTests {
    @Test(
        "Caches resolved packages to cache storages",
        .sharedResolvedPackagesTrait,
        arguments: CachePolicyEntry.allCases
    )
    func cacheResolvedPackages(entries: [CachePolicyEntry]) async throws {
        defer {
            entries.cleanup(using: fileSystem)
        }

        let testContext = try #require(TestContext.shared)
        let originHash = try #require(testContext.originHash)

        let cacheSystem = PackageResolver.CacheSystem(
            fileSystem: fileSystem,
            packageLocator: packageLocation,
            cachePolicies: entries.map(\.cachePolicy)
        )

        await cacheSystem.cacheResolvedPackages(testContext.resolvedPackages, for: originHash)

        #expect(
            try await entries.allHaveValidCache(
                for: originHash,
                packageLocator: packageLocation,
                fileSystem: fileSystem
            )
        )
    }

    @Test(
        "Returns noCache when no resolved packages cache exists",
        .sharedResolvedPackagesTrait,
        arguments: CachePolicyEntry.allCases
    )
    func returnsNoCacheWhenCacheDoesNotExist(entries: [CachePolicyEntry]) async throws {
        defer {
            entries.cleanup(using: fileSystem)
        }

        let testContext = try #require(TestContext.shared)
        let originHash = try #require(testContext.originHash)

        let cacheSystem = PackageResolver.CacheSystem(
            fileSystem: fileSystem,
            packageLocator: packageLocation,
            cachePolicies: entries.map(\.cachePolicy)
        )

        let result = await cacheSystem.restoreCacheIfPossible(for: originHash)

        switch result {
        case .restored, .failed:
            Issue.record("Should have returned .noCache, but instead got \(result)")
        default: break
        }
    }

    @Test(
        "Returns valid cache when a resolved packages cache exists",
        .sharedResolvedPackagesTrait,
        arguments: CachePolicyEntry.allCases
    )
    func returnsValidCacheWhenCacheDoesExist(entries: [CachePolicyEntry]) async throws {
        defer {
            entries.cleanup(using: fileSystem)
        }

        let testContext = try #require(TestContext.shared)
        let originHash = try #require(testContext.originHash)

        let cacheSystem = PackageResolver.CacheSystem(
            fileSystem: fileSystem,
            packageLocator: packageLocation,
            cachePolicies: entries.map(\.cachePolicy)
        )

        await cacheSystem.cacheResolvedPackages(testContext.resolvedPackages, for: originHash)
        let result = await cacheSystem.restoreCacheIfPossible(for: originHash)

        switch result {
        case .restored(let resolvedPackages):
            #expect(testContext.resolvedPackages == resolvedPackages)
        case .noCache:
            Issue.record("Should have returned a cache, but instead got .noCache")
        case .failed(let localizedError):
            Issue.record("Should have returned a cache, but instead got a failure with error: \(localizedError)")
        }
    }

    @Test("Shares restored resolved packages to other cache storages", .sharedResolvedPackagesTrait)
    func sharesResolvedPackagesAcrossStorages() async throws {
        let testContext = try #require(TestContext.shared)
        let originHash = try #require(testContext.originHash)

        let projectCacheEntry: CachePolicyEntry = .project
        let localDiskCacheEntry: CachePolicyEntry = .localDisk

        let entries: [CachePolicyEntry] = [projectCacheEntry, localDiskCacheEntry, .inMemory()]

        defer {
            entries.cleanup(using: fileSystem)
        }

        let cacheSystem = PackageResolver.CacheSystem(
            fileSystem: fileSystem,
            packageLocator: packageLocation,
            cachePolicies: entries.map(\.cachePolicy)
        )

        await cacheSystem.cacheResolvedPackages(testContext.resolvedPackages, for: originHash)

        projectCacheEntry.cleanup(fileSystem)
        localDiskCacheEntry.cleanup(fileSystem)

        let result = await cacheSystem.restoreCacheIfPossible(for: originHash)

        #expect(
            try await [projectCacheEntry, localDiskCacheEntry].allHaveValidCache(
                for: originHash,
                packageLocator: packageLocation,
                fileSystem: fileSystem
            )
        )

        switch result {
        case .restored(let resolvedPackages):
            #expect(testContext.resolvedPackages == resolvedPackages)
        case .noCache:
            Issue.record("Should have returned a cache, but instead got .noCache")
        case .failed(let localizedError):
            Issue.record("Should have returned a cache, but instead got a failure with error: \(localizedError)")
        }
    }

    /// Represents a cache policy configuration with cleanup logic for testing.
    struct CachePolicyEntry: Sendable {
        let cachePolicy: Runner.Options.ResolvedPackagesCachePolicy
        let cleanup: @Sendable (any FileSystem) -> Void

        private static func localDisk(baseURL: URL) -> CachePolicyEntry {
            CachePolicyEntry(
                cachePolicy: .localDisk(baseURL: baseURL),
                cleanup: { fileSystem in
                    try? fileSystem.removeFileTree(baseURL)
                }
            )
        }

        static let project: CachePolicyEntry = CachePolicyEntry(
            cachePolicy: .project,
            cleanup: { fileSystem in
                try? fileSystem.removeFileTree(packageLocation.resolvedPackagesCacheDirectory)
            }
        )

        static let localDisk: CachePolicyEntry = .localDisk(baseURL: fileSystem.tempDirectory.appending(components: #fileID))

        static func inMemory() -> CachePolicyEntry {
            CachePolicyEntry(
                cachePolicy: .init(storage: .custom(InMemoryCacheStorage()), actors: [.producer, .consumer]),
                cleanup: { _ in }
            )
        }

        static let allCases: [[Self]] = [
            [.project],
            [.localDisk],
            [.inMemory()],
            [.project, .localDisk, .inMemory()]
        ]
    }
}

extension [PackageResolverCacheSystemTests.CachePolicyEntry] {
    /// Cleans up all cache entries.
    func cleanup(using fileSystem: some FileSystem) {
        forEach { $0.cleanup(fileSystem) }
    }

    /// Returns true if all cache entries have valid cached data for the given origin hash.
    func allHaveValidCache(
        for originHash: String,
        packageLocator: some PackageLocator,
        fileSystem: some FileSystem,
    ) async throws -> Bool {
        try await asyncAllSatisfy {
            try await $0.cachePolicy.storage
                .buildStorage(packageLocator: packageLocator, fileSystem: fileSystem)
                .existsValidCache(for: originHash)
        }
    }
}

/// Test trait that provides shared resolved packages.
fileprivate struct SharedResolvedPackagesTrait: TestTrait, TestScoping {
    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: () async throws -> Void
    ) async throws {
        let executor = ProcessExecutor()
        let manifestLoader = ManifestLoader(executor: executor)

        let rootManifest = try await manifestLoader.loadManifest(for: packageURL)

        let packageResolver: PackageResolver = await PackageResolver(
            packageLocator: PackageLocation(packageDirectory: packageURL),
            rootManifest: rootManifest,
            cachePolicies: [],
            fileSystem: LocalFileSystem.default
        )
        let modulesGraph = try await packageResolver.resolve()

        let context = TestContext(
            resolvedPackages: Array(modulesGraph.allPackages.values),
            originHash: UUID().uuidString
        )

        try await TestContext.$shared.withValue(context) {
            try await function()
        }
    }
}

fileprivate extension TestTrait where Self == SharedResolvedPackagesTrait {
    static var sharedResolvedPackagesTrait: Self { Self() }
}

/// In-memory implementation of resolved packages cache storage for testing.
private actor InMemoryCacheStorage: ResolvedPackagesCacheStorage {
    var caches: [String: [ScipioKitCore.ResolvedPackage]] = [:]

    func existsValidCache(for originHash: String) async throws -> Bool {
        caches[originHash] != nil
    }

    func fetchResolvedPackages(for originHash: String) async throws -> [ScipioKitCore.ResolvedPackage] {
        guard let cache = caches[originHash] else {
            throw Error.noCache
        }
        return cache
    }

    func cacheResolvedPackages(_ resolvedPackages: [ScipioKitCore.ResolvedPackage], for originHash: String) async throws {
        caches[originHash] = resolvedPackages
    }

    enum Error: Swift.Error {
        case noCache
    }
}

private struct PackageLocation: PackageLocator {
    let packageDirectory: URL
}

private struct TestContext: Sendable {
    let resolvedPackages: [ResolvedPackage]
    let originHash: String?

    @TaskLocal static var shared: Self?
}
