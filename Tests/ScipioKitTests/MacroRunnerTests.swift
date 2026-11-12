import CacheStorage
import Foundation
import Testing
@testable @_spi(Internals) import ScipioKit

struct MacroRunnerTests {
    private struct PluginManifest: Decodable {
        struct Plugin: Decodable, Equatable {
            let module: String
            let executable: String
            let targets: [String]
        }
        let plugins: [Plugin]
    }

    private struct LegacyStorage: FrameworkCacheStorage {
        func existsValidCache(for cacheKey: some CacheKey) async throws -> Bool { false }
        func fetchArtifacts(for cacheKey: some CacheKey, to destinationDir: URL) async throws {}
        func cacheFramework(_ frameworkPath: URL, for cacheKey: some CacheKey) async throws {}
    }

    @Test(.temporaryDirectory)
    func restoresMacroWhenFrameworkIsAlreadyCached() async throws {
        let manager = FileManager.default
        let root = TemporaryDirectory.url
        let source = root.appending(path: "MacroFixture")
        let parent = root.appending(path: "Parent")
        let output = root.appending(path: "XCFrameworks")
        let cache = root.appending(path: "cache")
        try manager.createDirectory(at: source.appending(path: "Sources/FixturePlugin"), withIntermediateDirectories: true)
        try manager.createDirectory(at: source.appending(path: "Sources/FixtureLibrary"), withIntermediateDirectories: true)
        try manager.createDirectory(at: source.appending(path: "Sources/FixtureConsumer"), withIntermediateDirectories: true)
        try manager.createDirectory(at: parent.appending(path: "Sources/Parent"), withIntermediateDirectories: true)

        try """
        // swift-tools-version: 6.0
        import PackageDescription
        import CompilerPluginSupport
        let package = Package(name: "MacroFixture", platforms: [.iOS(.v15), .macOS(.v14)],
            products: [.library(name: "FixtureConsumer", targets: ["FixtureConsumer"])],
            targets: [
                .macro(name: "FixturePlugin", dependencies: []),
                .target(name: "FixtureLibrary", dependencies: ["FixturePlugin"]),
                .target(name: "FixtureConsumer", dependencies: ["FixtureLibrary"])
            ])
        """.write(to: source.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
        try "@main struct Plugin { static func main() {} }".write(
            to: source.appending(path: "Sources/FixturePlugin/Plugin.swift"), atomically: true, encoding: .utf8
        )
        try "public struct Fixture {}".write(
            to: source.appending(path: "Sources/FixtureLibrary/Library.swift"), atomically: true, encoding: .utf8
        )
        try "public struct Consumer {}".write(
            to: source.appending(path: "Sources/FixtureConsumer/Consumer.swift"), atomically: true, encoding: .utf8
        )
        try git(["init", "-q", source.path])
        try git(["-C", source.path, "config", "user.email", "test@example.invalid"])
        try git(["-C", source.path, "config", "user.name", "Test"])
        try git(["-C", source.path, "add", "."])
        try git(["-C", source.path, "commit", "-qm", "Fixture"])
        try git(["-C", source.path, "tag", "1.0.0"])
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Parent", platforms: [.iOS(.v15)],
            dependencies: [.package(url: "\(source.absoluteString)", exact: "1.0.0")],
            targets: [.target(name: "Parent", dependencies: [
                .product(name: "FixtureConsumer", package: "MacroFixture")
            ])])
        """.write(to: parent.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
        try "struct Parent {}".write(
            to: parent.appending(path: "Sources/Parent/Parent.swift"), atomically: true, encoding: .utf8
        )

        let requiredRemote = Runner(mode: .prepareDependencies, options: .init(
            baseBuildOptions: .init(buildConfiguration: .debug, frameworkType: .static),
            frameworkCachePolicies: [.init(storage: LegacyStorage(), actors: [.producer])],
            resolvedPackagesCachePolicies: [],
            requireMacroArtifactStorage: true
        ))
        do {
            try await requiredRemote.run(packageDirectory: parent, frameworkOutputDir: .custom(output))
            Issue.record("A framework-only producer must not satisfy required macro publication")
        } catch MacroPluginProducer.Error.unsupportedProducer {
        }

        let runner = Runner(mode: .prepareDependencies, options: .init(
            baseBuildOptions: .init(buildConfiguration: .debug, frameworkType: .static),
            frameworkCachePolicies: [.localDisk(baseURL: cache)],
            resolvedPackagesCachePolicies: []
        ))
        try await runner.run(packageDirectory: parent, frameworkOutputDir: .custom(output))
        let framework = output.appending(path: "FixtureLibrary.xcframework")
        let version = output.appending(path: ".FixtureLibrary.version")
        let consumerFramework = output.appending(path: "FixtureConsumer.xcframework")
        let consumerVersion = output.appending(path: ".FixtureConsumer.version")
        #expect(manager.fileExists(atPath: consumerFramework.path))
        #expect(manager.fileExists(atPath: consumerVersion.path))
        let macroDirectory = parent.appending(components: ".build", "scipio", "MacroPlugins", "FixturePlugin")
        let macroExecutable = macroDirectory.appending(path: "FixturePlugin")
        let macroVersion = parent.appending(components: ".build", "scipio", "MacroPlugins", ".FixturePlugin.version")
        #expect(!manager.fileExists(atPath: root.appending(path: "MacroPlugins").path))
        let metadata = parent.appending(components: ".build", "scipio", "MacroPlugins", "plugins.json")
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: metadata))
        #expect(manifest.plugins == [
            .init(module: "FixturePlugin", executable: "FixturePlugin/FixturePlugin", targets: ["FixtureLibrary"]),
        ])
        let frameworkVersion = try Data(contentsOf: version)
        let executable = try Data(contentsOf: macroExecutable)
        let buildVersion = try await ProcessExecutor().execute(
            "/usr/bin/xcrun", "vtool", "-show-build", macroExecutable.path
        ).unwrapOutput()
        #expect(buildVersion.contains("platform MACOS"))
        #expect(buildVersion.contains("minos 14.0"))
        let modified = try #require(manager.attributesOfItem(atPath: framework.path)[.modificationDate] as? Date)
        try manager.removeItem(at: macroDirectory)
        try manager.removeItem(at: macroVersion)

        try await runner.run(packageDirectory: parent, frameworkOutputDir: .custom(output))

        #expect(try Data(contentsOf: macroExecutable) == executable)
        #expect(manager.isExecutableFile(atPath: macroExecutable.path))
        #expect(try Data(contentsOf: version) == frameworkVersion)
        #expect(try manager.attributesOfItem(atPath: framework.path)[.modificationDate] as? Date == modified)
        #expect(manager.fileExists(atPath: macroVersion.path))

        let macroKey = try JSONDecoder().decode(MacroCacheKey.self, from: Data(contentsOf: macroVersion))
        let cachedExecutable = try cache.appending(
            components: "Scipio", "Macros", "FixturePlugin", macroKey.calculateChecksum(), "FixturePlugin", "FixturePlugin"
        )
        try Data("corrupt".utf8).write(to: cachedExecutable)
        try manager.removeItem(at: macroDirectory)
        try manager.removeItem(at: macroVersion)

        try await runner.run(packageDirectory: parent, frameworkOutputDir: .custom(output))

        #expect(try Data(contentsOf: macroExecutable) == executable)
        #expect(try Data(contentsOf: cachedExecutable) == executable)
        #expect(try manager.attributesOfItem(atPath: framework.path)[.modificationDate] as? Date == modified)

        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Parent", platforms: [.iOS(.v15)],
            dependencies: [.package(path: "\(source.path)")],
            targets: [.target(name: "Parent", dependencies: [
                .product(name: "FixtureConsumer", package: "MacroFixture")
            ])])
        """.write(to: parent.appending(path: "Package.swift"), atomically: true, encoding: .utf8)

        try await runner.run(packageDirectory: parent, frameworkOutputDir: .custom(output))
        #expect(manager.fileExists(atPath: framework.path))
        #expect(!manager.fileExists(atPath: version.path))
        #expect(manager.fileExists(atPath: consumerFramework.path))
        #expect(!manager.fileExists(atPath: consumerVersion.path))
        #expect(!manager.fileExists(atPath: macroVersion.path))
    }

    private func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableRuntimeMismatch)
        }
    }
}
