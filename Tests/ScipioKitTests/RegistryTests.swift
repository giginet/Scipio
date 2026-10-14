import Foundation
import Testing
@testable @_spi(Internals) import ScipioKit
@testable import ScipioKitCore

struct RegistryTests {
    @Test(.temporaryDirectory)
    func authenticatedRegistryAndCache() async throws {
        // Prepare a temporary directory and a unique identity for the test package.
        let directory = TemporaryDirectory.url
        let packageName = "library" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

        // Start a local registry that requires Basic authentication and serves a versioned package.
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let fixture = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(components: "Resources", "Fixtures", "AuthenticatedRegistry", "server.py")
        let portFile = directory.appendingPathComponent("port")
        server.arguments = [fixture.path, portFile.path, packageName]
        let termination = AsyncStream<Void> { continuation in
            server.terminationHandler = { _ in continuation.finish() }
        }
        try server.run()

        do {
            // Wait for the registry to publish its port, then configure the consumer package to use it.
            for _ in 0..<100 {
                if FileManager.default.fileExists(atPath: portFile.path) { break }
                try await Task.sleep(for: .milliseconds(50))
            }

            let port = try String(contentsOf: portFile, encoding: .utf8)
            try configureConsumer(at: directory, registryPort: port, packageName: packageName)

            // Invalid credentials must fail resolution, with a rejection recorded by the registry.
            let netrc = directory.appendingPathComponent("netrc")
            try "machine 127.0.0.1 login fixture password wrong-password".write(to: netrc, atomically: true, encoding: .utf8)
            await #expect(throws: (any Error).self) {
                _ = try await resolveConsumer(at: directory, netrc: netrc)
            }
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("port.rejected").path))

            // Correct credentials must resolve the package and download its source archive.
            try "machine 127.0.0.1 login fixture password fixture-password".write(to: netrc, atomically: true, encoding: .utf8)
            let graph = try await resolveConsumer(at: directory, netrc: netrc)
            let package = try #require(graph.allPackages.values.first { $0.id.packageIdentity == "example.\(packageName)" })
            let module = try #require(package.targets.first { $0.name == "RegistryLibrary" })
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("port.downloaded").path))
            #expect(package.resolvedPackageKind == .registry("example.\(packageName)"))

            // Registry cache keys must include the scoped identity and version without a Git revision.
            let target = CacheSystem.CacheTarget(buildProduct: BuildProduct(package: package, target: module), buildOptions: buildOptions())
            let cache = CacheSystem(outputDirectory: directory)
            let dependencyGraph = try DependencyGraph.resolve(Set([target]), id: \.buildProduct.target.name, childIDs: { _ in [] })
            let keys = try await cache.calculateCacheKeys(for: dependencyGraph)
            let key = try #require(keys[target])
            #expect(key.pin == .registry(identity: "example.\(packageName)", version: "1.0.0"))
            #expect(key.localPackageCanonicalLocation == nil)

            // The saved version file must round-trip and remain valid for the same cache key.
            try await cache.generateVersionFile(for: target, cacheKey: key)
            #expect(try VersionFileDecoder().decode(versionFile: directory.appendingPathComponent(".RegistryLibrary.version")) == key)
            let valid = await cache.existsValidCache(cacheKey: key)
            #expect(valid)

            // A different package version or identity must invalidate the saved cache key.
            for pin in [
                Pin.State.registry(identity: "example.\(packageName)", version: "1.0.1"),
                .registry(identity: "other.\(packageName)", version: "1.0.0"),
            ] {
                var changed = key
                changed.pin = pin
                let changedValid = await cache.existsValidCache(cacheKey: changed)
                #expect(!changedValid)
                #expect(try changed.calculateChecksum() != key.calculateChecksum())
            }
        } catch {
            await stopRegistry(server, termination: termination)
            throw error
        }
        await stopRegistry(server, termination: termination)
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

    private func stopRegistry(_ server: Process, termination: AsyncStream<Void>) async {
        if server.isRunning { server.terminate() }
        for await _ in termination {}
    }

    private func resolveConsumer(at directory: URL, netrc: URL) async throws -> ModulesGraph {
        let executor = RegistryExecutor(netrc: netrc, cacheDirectory: directory.appendingPathComponent("cache"))
        let manifest = try await ManifestLoader(executor: executor).loadManifest(for: directory)
        let resolver = await PackageResolver(
            packageLocator: ConsumerLocation(packageDirectory: directory), rootManifest: manifest,
            cachePolicies: [], fileSystem: LocalFileSystem.default, executor: executor
        )
        return try await resolver.resolve()
    }

    private func buildOptions() -> BuildOptions {
        BuildOptions(
            buildConfiguration: .release, isDebugSymbolsEmbedded: false, frameworkType: .dynamic,
            sdks: [.iOS], extraFlags: nil, extraBuildParameters: nil, enableLibraryEvolution: false,
            keepPublicHeadersStructure: false, customFrameworkModuleMapContents: nil, stripStaticDWARFSymbols: false
        )
    }

    private func configureConsumer(at directory: URL, registryPort: String, packageName: String) throws {
        let configuration = directory.appendingPathComponent(".swiftpm/configuration")
        try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: true)
        let registryConfiguration = """
        {"version":1,"registries":{"example":{"url":"http://127.0.0.1:\(registryPort)","supportsAvailability":false}},
        "authentication":{"127.0.0.1:\(registryPort)":{"type":"basic"}}}
        """
        try registryConfiguration.write(to: configuration.appendingPathComponent("registries.json"), atomically: true, encoding: .utf8)

        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Consumer", platforms: [.iOS(.v14)], dependencies: [
            .package(id: "example.\(packageName)", exact: "1.0.0")
        ], targets: [.target(name: "Consumer", dependencies: [
            .product(name: "RegistryLibrary", package: "example.\(packageName)")
        ])])
        """
        try manifest.write(to: directory.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let sources = directory.appendingPathComponent("Sources/Consumer")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "import RegistryLibrary".write(to: sources.appendingPathComponent("Consumer.swift"), atomically: true, encoding: .utf8)
    }
}

private struct ConsumerLocation: PackageLocator {
    let packageDirectory: URL
}

/// Uses fixture credentials and an isolated cache for the SwiftPM subprocesses.
private struct RegistryExecutor: Executor {
    let netrc: URL
    let cacheDirectory: URL

    func execute(_ arguments: [String], environment: [String: String]?) async throws -> any ExecutorResult {
        let options = ["--netrc", "--netrc-file", netrc.path, "--disable-keychain", "--cache-path", cacheDirectory.path]
        var commands = arguments
        let packageIndex = try #require(commands.firstIndex(of: "package"))
        commands.insert(contentsOf: options, at: packageIndex + 1)
        return try await ProcessExecutor().execute(commands, environment: environment)
    }
}
