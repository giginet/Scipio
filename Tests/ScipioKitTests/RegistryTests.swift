import Foundation
import Testing
@testable @_spi(Internals) import ScipioKit
@testable import ScipioKitCore

struct RegistryTests {
    @Test(.temporaryDirectory)
    func registryAndCache() async throws {
        // Prepare a consumer and SwiftPM responses for a registry dependency.
        let directory = TemporaryDirectory.url
        let fixture = try RegistryResolutionFixture(at: directory)
        let executor = fixture.makeExecutor()
        let manifest = try await ManifestLoader(executor: executor).loadManifest(for: directory)
        let resolver = await PackageResolver(
            packageLocator: fixture, rootManifest: manifest,
            cachePolicies: [], fileSystem: LocalFileSystem.default, executor: executor
        )

        // Resolve the registry package from SwiftPM output.
        let graph = try await resolver.resolve()
        let package = try #require(graph.allPackages.values.first { $0.id.packageIdentity == "example.library" })
        let module = try #require(package.targets.first { $0.name == "RegistryLibrary" })
        #expect(package.resolvedPackageKind == .registry("example.library"))
        #expect(package.pinState == .registry(identity: "example.library", version: "1.0.0"))
        #expect(module.resolvedModuleType == .swift)
        #expect(await executor.calledArguments.contains { $0.contains("resolve") })

        // Registry cache keys must include the scoped identity and version.
        let target = CacheSystem.CacheTarget(buildProduct: BuildProduct(package: package, target: module), buildOptions: buildOptions())
        let cache = CacheSystem(outputDirectory: directory)
        let dependencyGraph = try DependencyGraph.resolve(Set([target]), id: \.buildProduct.target.name, childIDs: { _ in [] })
        let keys = try await cache.calculateCacheKeys(for: dependencyGraph)
        let key = try #require(keys[target])
        #expect(key.pin == .registry(identity: "example.library", version: "1.0.0"))
        #expect(key.localPackageCanonicalLocation == nil)

        // The saved version file must round-trip and remain valid for the same cache key.
        try await cache.generateVersionFile(for: target, cacheKey: key)
        #expect(try VersionFileDecoder().decode(versionFile: directory.appendingPathComponent(".RegistryLibrary.version")) == key)
        let valid = await cache.existsValidCache(cacheKey: key)
        #expect(valid)

        // A different package version or identity must invalidate the saved cache key.
        for pin in [
            Pin.State.registry(identity: "example.library", version: "1.0.1"),
            .registry(identity: "other.library", version: "1.0.0"),
        ] {
            var changed = key
            changed.pin = pin
            let changedValid = await cache.existsValidCache(cacheKey: changed)
            #expect(!changedValid)
            #expect(try changed.calculateChecksum() != key.calculateChecksum())
        }
    }

    @Test(.temporaryDirectory)
    func registryWithoutPinCannotUseGitRevision() async throws {
        // A tagged Git repository around a registry download must not substitute for its missing pin.
        let directory = TemporaryDirectory.url
        let executor = ProcessExecutor()
        try await executor.execute(["/usr/bin/git", "init", directory.path])
        try await executor.execute([
            "/usr/bin/git", "-C", directory.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com",
            "commit", "--allow-empty", "-m", "Fixture",
        ])
        try await executor.execute(["/usr/bin/git", "-C", directory.path, "tag", "1.0.0"])
        let module = try ResolvedGraphFixtures.resolvedModule(name: "RegistryLibrary")
        var package = try ResolvedGraphFixtures.package(identity: "example.library", targets: [module])
        package.resolvedPackageKind = .registry("example.library")
        package.path = directory.path
        let target = CacheSystem.CacheTarget(buildProduct: BuildProduct(package: package, target: module), buildOptions: buildOptions())
        let graph = try DependencyGraph.resolve(Set([target]), id: \.buildProduct.target.name, childIDs: { _ in [] })
        let keys = try await CacheSystem(outputDirectory: directory).calculateCacheKeys(for: graph)
        #expect(keys[target] == nil)
    }

    private func buildOptions() -> BuildOptions {
        BuildOptions(
            buildConfiguration: .release, isDebugSymbolsEmbedded: false, frameworkType: .dynamic,
            sdks: [.iOS], extraFlags: nil, extraBuildParameters: nil, enableLibraryEvolution: false,
            keepPublicHeadersStructure: false, customFrameworkModuleMapContents: nil, stripStaticDWARFSymbols: false
        )
    }
}

/// Prepares a consumer package and supplies SwiftPM responses for its registry dependency.
private struct RegistryResolutionFixture: PackageLocator {
    let packageDirectory: URL

    private var dependencyDirectory: URL {
        packageDirectory.appendingPathComponent(".build/registry/downloads/example/library/1.0.0")
    }

    init(at directory: URL) throws {
        self.packageDirectory = directory
        for (package, target) in [(packageDirectory, "Consumer"), (dependencyDirectory, "RegistryLibrary")] {
            let sources = package.appendingPathComponent("Sources/\(target)")
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            try "public struct Library {}".write(to: sources.appendingPathComponent("Library.swift"), atomically: true, encoding: .utf8)
        }
        try #"{"version":3,"pins":[{"identity":"example.library","kind":"registry","location":"","state":{"version":"1.0.0"}}]}"#
            .write(to: directory.appendingPathComponent("Package.resolved"), atomically: true, encoding: .utf8)
    }

    func makeExecutor() -> StubbableExecutor {
        StubbableExecutor { arguments in
            StubbableExecutorResult(arguments: arguments, success: try response(for: arguments))
        }
    }

    private func response(for arguments: [String]) throws -> String {
        switch Array(arguments.prefix(4)) {
        case ["/usr/bin/xcrun", "swift", "package", "resolve"]:
            return ""
        case ["/usr/bin/xcrun", "swift", "package", "show-dependencies"]:
            return try dependencyTree()
        case ["/usr/bin/xcrun", "swift", "package", "dump-package"]:
            guard let index = arguments.firstIndex(of: "--package-path"), arguments.indices.contains(index + 1) else {
                throw FixtureError.unexpectedCommand(arguments)
            }
            switch arguments[index + 1] {
            case packageDirectory.path: return try consumerManifest()
            case dependencyDirectory.path: return try dependencyManifest()
            default: throw FixtureError.unexpectedCommand(arguments)
            }
        default:
            throw FixtureError.unexpectedCommand(arguments)
        }
    }

    private func consumerManifest() throws -> String {
        try json([
            "name": "Consumer", "toolsVersion": ["_version": "6.0.0"],
            "packageKind": ["root": [packageDirectory.path]],
            "dependencies": [["registry": [[
                "identity": "example.library", "requirement": ["exact": ["1.0.0"]],
                "productFilter": NSNull(),
            ]]]],
            "products": [],
            "targets": [target("Consumer", dependencies: [
                ["product": ["RegistryLibrary", "example.library", NSNull(), NSNull()]],
            ])],
        ])
    }

    private func dependencyManifest() throws -> String {
        // dump-package reports root even for a downloaded registry dependency.
        try json([
            "name": "RegistryLibrary", "toolsVersion": ["_version": "6.0.0"],
            "packageKind": ["root": [dependencyDirectory.path]], "dependencies": [],
            "products": [["name": "RegistryLibrary", "targets": ["RegistryLibrary"], "type": ["library": ["automatic"]]]],
            "targets": [target("RegistryLibrary")],
        ])
    }

    private func dependencyTree() throws -> String {
        try json([
            "identity": "consumer", "name": "Consumer", "url": packageDirectory.path,
            "version": "unspecified", "path": packageDirectory.path,
            "dependencies": [[
                "identity": "example.library", "name": "RegistryLibrary", "url": "example.library",
                "version": "1.0.0", "path": dependencyDirectory.path, "dependencies": [],
            ]],
        ])
    }

    private func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func target(_ name: String, dependencies: [[String: Any]] = []) -> [String: Any] {
        [
            "name": name, "type": "regular", "packageAccess": false,
            "dependencies": dependencies, "resources": [], "exclude": [], "settings": [],
        ]
    }

    private enum FixtureError: Error {
        case unexpectedCommand([String])
    }
}
