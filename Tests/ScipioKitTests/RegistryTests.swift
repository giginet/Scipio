import Foundation
import Testing
@testable @_spi(Internals) import ScipioKit
@testable import ScipioKitCore

struct RegistryTests {
    @Test(.temporaryDirectory)
    func registryAndCache() async throws {
        // Prepare a consumer and SwiftPM responses for a registry dependency.
        let directory = TemporaryDirectory.url
        let identity = "example.library"
        let version = "1.0.0"
        let registryURL = "https://packages.example.com"
        let targetName = "RegistryLibrary"
        let fixture = try RegistryResolutionFixture(
            at: directory, identity: identity, version: version,
            registryURL: registryURL, targetName: targetName
        )
        let executor = fixture.makeExecutor()
        let manifest = try await ManifestLoader(executor: executor).loadManifest(for: directory)
        let resolver = await PackageResolver(
            packageLocator: fixture, rootManifest: manifest,
            cachePolicies: [], fileSystem: LocalFileSystem.default, executor: executor
        )

        // Resolve the registry package from SwiftPM output.
        let graph = try await resolver.resolve()
        let package = try #require(graph.allPackages.values.first { $0.id.packageIdentity == identity })
        let module = try #require(package.targets.first { $0.name == targetName })
        #expect(package.resolvedPackageKind == .registry(identity))
        #expect(package.pinState == .registry(identity: identity, version: version))
        #expect(module.resolvedModuleType == .swift)
        #expect(await executor.calledArguments.contains { $0.contains("resolve") })

        // Registry cache keys must include the scoped identity and version.
        let target = CacheSystem.CacheTarget(buildProduct: BuildProduct(package: package, target: module), buildOptions: buildOptions())
        let cache = CacheSystem(outputDirectory: directory)
        let dependencyGraph = try DependencyGraph.resolve(Set([target]), id: \.buildProduct.target.name, childIDs: { _ in [] })
        let keys = try await cache.calculateCacheKeys(for: dependencyGraph)
        let key = try #require(keys[target])
        #expect(key.pin == .registry(identity: identity, version: version))
        #expect(key.localPackageCanonicalLocation == nil)
        #expect(key.registryURL == URL(string: registryURL))

        // The saved version file must round-trip and remain valid for the same cache key.
        try await cache.generateVersionFile(for: target, cacheKey: key)
        #expect(try VersionFileDecoder().decode(versionFile: directory.appendingPathComponent(".\(targetName).version")) == key)
        let valid = await cache.existsValidCache(cacheKey: key)
        #expect(valid)

        // The same identity and version from another registry must not restore this cache.
        try fixture.writeMetadata(registry: "https://other.example.com")
        let otherKeys = try await cache.calculateCacheKeys(for: dependencyGraph)
        let otherKey = try #require(otherKeys[target])
        #expect(otherKey.pin == key.pin)
        #expect(try otherKey.calculateChecksum() != key.calculateChecksum())
        #expect(await cache.existsValidCache(cacheKey: otherKey) == false)

        // A different package version or identity must invalidate the saved cache key.
        for pin in [
            Pin.State.registry(identity: identity, version: "1.0.1"),
            .registry(identity: "other.library", version: version),
        ] {
            var changed = key
            changed.pin = pin
            let changedValid = await cache.existsValidCache(cacheKey: changed)
            #expect(!changedValid)
            #expect(try changed.calculateChecksum() != key.calculateChecksum())
        }
    }

    @Test(
        "A registry package requires readable metadata with a registry URL",
        .temporaryDirectory,
        arguments: [nil, "{}", "{", #"{"registry":123}"#] as [String?]
    )
    func registryWithoutMetadataCannotCalculateCacheKey(metadata: String?) async throws {
        let directory = TemporaryDirectory.url
        let identity = "example.library"
        let module = try ResolvedGraphFixtures.resolvedModule(name: "RegistryLibrary")
        var package = try ResolvedGraphFixtures.package(
            identity: identity, targets: [module],
            pinState: .registry(identity: identity, version: "1.0.0")
        )
        package.resolvedPackageKind = .registry(identity)
        package.path = directory.path

        if let metadata {
            try metadata.write(
                to: directory.appendingPathComponent(".registry-metadata"),
                atomically: true, encoding: .utf8
            )
        }

        let target = CacheSystem.CacheTarget(buildProduct: BuildProduct(package: package, target: module), buildOptions: buildOptions())
        let graph = try DependencyGraph.resolve(Set([target]), id: \.buildProduct.target.name, childIDs: { _ in [] })
        let keys = try await CacheSystem(outputDirectory: directory).calculateCacheKeys(for: graph)
        #expect(keys[target] == nil)
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
    let identity: String
    let version: String
    let targetName: String

    private var dependencyDirectory: URL {
        packageDirectory.appendingPathComponent(".build/registry/downloads/\(identity.replacingOccurrences(of: ".", with: "/"))/\(version)")
    }

    init(at directory: URL, identity: String, version: String, registryURL: String, targetName: String) throws {
        self.packageDirectory = directory
        self.identity = identity
        self.version = version
        self.targetName = targetName
        for (package, target) in [(packageDirectory, "Consumer"), (dependencyDirectory, targetName)] {
            let sources = package.appendingPathComponent("Sources/\(target)")
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            try "public struct Library {}".write(to: sources.appendingPathComponent("Library.swift"), atomically: true, encoding: .utf8)
        }
        try JSONEncoder().encode(ResolvedFileFixture(pins: [
            .init(identity: identity, state: .init(version: version)),
        ])).write(to: directory.appendingPathComponent("Package.resolved"))
        try writeMetadata(registry: registryURL)
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
        try json(ManifestFixture(
            name: "Consumer", packageKind: .init(root: [packageDirectory.path]),
            dependencies: [.init(registry: [.init(identity: identity, requirement: .init(exact: [version]))])], products: [],
            targets: [.init(name: "Consumer", dependencies: [.init(name: targetName, package: identity)])]
        ))
    }

    private func dependencyManifest() throws -> String {
        // dump-package reports root even for a downloaded registry dependency.
        try json(ManifestFixture(
            name: targetName, packageKind: .init(root: [dependencyDirectory.path]),
            dependencies: [], products: [.init(name: targetName, targets: [targetName])], targets: [.init(name: targetName)]
        ))
    }

    private func dependencyTree() throws -> String {
        try json(DependencyFixture(
            identity: "consumer", name: "Consumer", url: packageDirectory.path,
            version: "unspecified", path: packageDirectory.path,
            dependencies: [.init(
                identity: identity, name: targetName, url: identity,
                version: version, path: dependencyDirectory.path, dependencies: []
            )]
        ))
    }

    private func json(_ value: some Encodable) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    func writeMetadata(registry: String) throws {
        try JSONEncoder().encode(RegistryMetadataFixture(registry: registry))
            .write(to: dependencyDirectory.appendingPathComponent(".registry-metadata"))
    }

    private struct ResolvedFileFixture: Encodable {
        let version = 3
        let pins: [Pin]

        struct Pin: Encodable {
            let identity: String
            let kind = "registry"
            let location = ""
            let state: State
        }

        struct State: Encodable {
            let version: String
        }
    }

    private struct RegistryMetadataFixture: Encodable {
        let registry: String
    }

    private struct DependencyFixture: Encodable {
        let identity: String
        let name: String
        let url: String
        let version: String
        let path: String
        let dependencies: [Self]
    }

    private struct ManifestFixture: Encodable {
        let name: String
        var toolsVersion = ToolsVersion()
        let packageKind: PackageKind
        let dependencies: [Dependency]
        let products: [Product]
        let targets: [Target]

        struct ToolsVersion: Encodable {
            let _version = "6.0.0"
        }

        struct PackageKind: Encodable {
            let root: [String]
        }

        struct Dependency: Encodable {
            let registry: [Registry]

            struct Registry: Encodable {
                let identity: String
                let requirement: Requirement
                let productFilter: String? = nil

                enum CodingKeys: String, CodingKey {
                    case identity, requirement, productFilter
                }

                func encode(to encoder: any Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode(identity, forKey: .identity)
                    try container.encode(requirement, forKey: .requirement)
                    try container.encodeNil(forKey: .productFilter)
                }
            }

            struct Requirement: Encodable {
                let exact: [String]
            }
        }

        struct Product: Encodable {
            let name: String
            let targets: [String]
            let type = ProductType()

            struct ProductType: Encodable {
                let library = ["automatic"]
            }
        }

        struct Target: Encodable {
            let name: String
            let type = "regular"
            let packageAccess = false
            var dependencies: [ProductDependency] = []
            let resources: [String] = []
            let exclude: [String] = []
            let settings: [String] = []
        }

        struct ProductDependency: Encodable {
            let name: String
            let package: String

            enum CodingKeys: String, CodingKey {
                case product
            }

            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                var product = container.nestedUnkeyedContainer(forKey: .product)
                try product.encode(name)
                try product.encode(package)
                try product.encodeNil()
                try product.encodeNil()
            }
        }
    }

    private enum FixtureError: Error {
        case unexpectedCommand([String])
    }
}
