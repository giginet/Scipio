import Foundation
@testable @_spi(Internals) import ScipioKit
import ScipioKitCore
import Testing
import CacheStorage

package let packageURL = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .appending(components: "Resources", "Fixtures", "TestingPackage")
private let fileSystem: LocalFileSystem = .default

struct PackageResolverCacheSystemTests {
    @Test(
        "Caches resolved packages to cache storages",
        .sharedResolvedPackagesTrait,
        arguments: CachePolicyKind.allCases
    )
    func cacheResolvedPackages(kinds: [CachePolicyKind]) async throws {
        let testContext = try #require(TestContext.shared)
        let originHash = try #require(testContext.originHash)
        let entries = CachePolicyEntry.entries(for: kinds, context: testContext)

        defer {
            entries.cleanup(using: fileSystem)
        }

        let cacheSystem = PackageResolver.CacheSystem(
            fileSystem: fileSystem,
            packageLocator: testContext.packageLocation,
            cachePolicies: entries.map(\.cachePolicy)
        )

        await cacheSystem.cacheResolvedPackages(testContext.resolvedPackages, for: originHash)

        #expect(
            try await entries.allHaveValidCache(
                for: originHash,
                packageLocator: testContext.packageLocation,
                fileSystem: fileSystem
            )
        )
    }

    @Test(
        "Returns noCache when no resolved packages cache exists",
        .sharedResolvedPackagesTrait,
        arguments: CachePolicyKind.allCases
    )
    func returnsNoCacheWhenCacheDoesNotExist(kinds: [CachePolicyKind]) async throws {
        let testContext = try #require(TestContext.shared)
        let originHash = try #require(testContext.originHash)
        let entries = CachePolicyEntry.entries(for: kinds, context: testContext)

        defer {
            entries.cleanup(using: fileSystem)
        }

        let cacheSystem = PackageResolver.CacheSystem(
            fileSystem: fileSystem,
            packageLocator: testContext.packageLocation,
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
        arguments: CachePolicyKind.allCases
    )
    func returnsValidCacheWhenCacheDoesExist(kinds: [CachePolicyKind]) async throws {
        let testContext = try #require(TestContext.shared)
        let originHash = try #require(testContext.originHash)
        let entries = CachePolicyEntry.entries(for: kinds, context: testContext)

        defer {
            entries.cleanup(using: fileSystem)
        }

        let cacheSystem = PackageResolver.CacheSystem(
            fileSystem: fileSystem,
            packageLocator: testContext.packageLocation,
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

        let projectCacheEntry = CachePolicyEntry.project(context: testContext)
        let localDiskCacheEntry = CachePolicyEntry.localDisk(context: testContext)

        let entries: [CachePolicyEntry] = [projectCacheEntry, localDiskCacheEntry, .inMemory()]

        defer {
            entries.cleanup(using: fileSystem)
        }

        let cacheSystem = PackageResolver.CacheSystem(
            fileSystem: fileSystem,
            packageLocator: testContext.packageLocation,
            cachePolicies: entries.map(\.cachePolicy)
        )

        await cacheSystem.cacheResolvedPackages(testContext.resolvedPackages, for: originHash)

        projectCacheEntry.cleanup(fileSystem)
        localDiskCacheEntry.cleanup(fileSystem)

        let result = await cacheSystem.restoreCacheIfPossible(for: originHash)

        #expect(
            try await [projectCacheEntry, localDiskCacheEntry].allHaveValidCache(
                for: originHash,
                packageLocator: testContext.packageLocation,
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

    enum CachePolicyKind: Sendable {
        case project
        case localDisk
        case inMemory

        static let allCases: [[Self]] = [
            [.project],
            [.localDisk],
            [.inMemory],
            [.project, .localDisk, .inMemory],
        ]
    }

    /// Represents a cache policy configuration with cleanup logic for testing.
    struct CachePolicyEntry: Sendable {
        let cachePolicy: Runner.Options.ResolvedPackagesCachePolicy
        let cleanup: @Sendable (any FileSystem) -> Void

        fileprivate static func entries(for kinds: [CachePolicyKind], context: TestContext) -> [CachePolicyEntry] {
            kinds.map { kind in
                switch kind {
                case .project:
                    project(context: context)
                case .localDisk:
                    localDisk(context: context)
                case .inMemory:
                    inMemory()
                }
            }
        }

        fileprivate static func project(context: TestContext) -> CachePolicyEntry {
            CachePolicyEntry(
                cachePolicy: .project,
                cleanup: { fileSystem in
                    try? fileSystem.removeFileTree(context.packageLocation.resolvedPackagesCacheDirectory)
                }
            )
        }

        fileprivate static func localDisk(context: TestContext) -> CachePolicyEntry {
            CachePolicyEntry(
                cachePolicy: .localDisk(baseURL: context.localDiskCacheDirectory),
                cleanup: { fileSystem in
                    try? fileSystem.removeFileTree(context.localDiskCacheDirectory)
                }
            )
        }

        static func inMemory() -> CachePolicyEntry {
            CachePolicyEntry(
                cachePolicy: .init(storage: .custom(InMemoryCacheStorage()), actors: [.producer, .consumer]),
                cleanup: { _ in }
            )
        }
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
private struct SharedResolvedPackagesTrait: TestTrait, TestScoping {
    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: () async throws -> Void
    ) async throws {
        let temporaryDirectory = fileSystem.tempDirectory
            .appending(components: "PackageResolverCacheSystemTests", UUID().uuidString)
        let temporaryPackageURL = temporaryDirectory.appending(component: "TestingPackage")

        try fileSystem.createDirectory(temporaryDirectory, recursive: true)
        try fileSystem.copy(from: packageURL, to: temporaryPackageURL)

        defer {
            try? fileSystem.removeFileTree(temporaryDirectory)
        }

        let executor = ProcessExecutor()
        let manifestLoader = ManifestLoader(executor: executor)

        let rootManifest = try await manifestLoader.loadManifest(for: temporaryPackageURL)

        let packageLocation = PackageLocation(packageDirectory: temporaryPackageURL)
        let packageResolver: PackageResolver = await PackageResolver(
            packageLocator: packageLocation,
            rootManifest: rootManifest,
            cachePolicies: [],
            fileSystem: LocalFileSystem.default
        )
        let modulesGraph = try await packageResolver.resolve()

        let context = TestContext(
            resolvedPackages: Array(modulesGraph.allPackages.values),
            originHash: UUID().uuidString,
            packageLocation: packageLocation,
            localDiskCacheDirectory: temporaryDirectory.appending(component: "LocalDiskCache")
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
    let packageLocation: PackageLocation
    let localDiskCacheDirectory: URL

    @TaskLocal static var shared: Self?
}
