import CacheStorage
import Foundation
import Testing
@testable import ScipioKit

struct MacroRunnerTests {
    private struct LegacyStorage: FrameworkCacheStorage {
        func existsValidCache(for cacheKey: some CacheKey) async throws -> Bool { false }
        func fetchArtifacts(for cacheKey: some CacheKey, to destinationDir: URL) async throws {}
        func cacheFramework(_ frameworkPath: URL, for cacheKey: some CacheKey) async throws {}
    }

    @Test func restoresMacroWhenFrameworkIsAlreadyCached() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("ScipioMacroTest-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        let source = root.appendingPathComponent("MacroFixture")
        let parent = root.appendingPathComponent("Parent")
        let output = root.appendingPathComponent("XCFrameworks")
        let cache = root.appendingPathComponent("cache")
        try manager.createDirectory(at: source.appendingPathComponent("Sources/FixturePlugin"), withIntermediateDirectories: true)
        try manager.createDirectory(at: source.appendingPathComponent("Sources/FixtureLibrary"), withIntermediateDirectories: true)
        try manager.createDirectory(at: parent.appendingPathComponent("Sources/Parent"), withIntermediateDirectories: true)

        try """
        // swift-tools-version: 6.0
        import PackageDescription
        import CompilerPluginSupport
        let package = Package(name: "MacroFixture", platforms: [.iOS(.v15)],
            products: [.library(name: "FixtureLibrary", targets: ["FixtureLibrary"])],
            targets: [
                .macro(name: "FixturePlugin", dependencies: []),
                .target(name: "FixtureLibrary", dependencies: ["FixturePlugin"])
            ])
        """.write(to: source.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "@main struct Plugin { static func main() {} }".write(
            to: source.appendingPathComponent("Sources/FixturePlugin/Plugin.swift"), atomically: true, encoding: .utf8
        )
        try "public struct Fixture {}".write(
            to: source.appendingPathComponent("Sources/FixtureLibrary/Library.swift"), atomically: true, encoding: .utf8
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
                .product(name: "FixtureLibrary", package: "MacroFixture")
            ])])
        """.write(to: parent.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "struct Parent {}".write(
            to: parent.appendingPathComponent("Sources/Parent/Parent.swift"), atomically: true, encoding: .utf8
        )

        let requiredRemote = Runner(mode: .prepareDependencies, options: .init(
            baseBuildOptions: .init(buildConfiguration: .debug, platforms: .specific([.iOS]), frameworkType: .static),
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
            baseBuildOptions: .init(buildConfiguration: .debug, platforms: .specific([.iOS]), frameworkType: .static),
            frameworkCachePolicies: [.localDisk(baseURL: cache)],
            resolvedPackagesCachePolicies: []
        ))
        try await runner.run(packageDirectory: parent, frameworkOutputDir: .custom(output))
        let framework = output.appendingPathComponent("FixtureLibrary.xcframework")
        let version = output.appendingPathComponent(".FixtureLibrary.version")
        let macroDirectory = root.appendingPathComponent("MacroPlugins/FixturePlugin")
        let macroExecutable = macroDirectory.appendingPathComponent("FixturePlugin")
        let macroVersion = root.appendingPathComponent("MacroPlugins/.FixturePlugin.version")
        let frameworkVersion = try Data(contentsOf: version)
        let executable = try Data(contentsOf: macroExecutable)
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
        let cachedExecutable = try cache.appendingPathComponent("Scipio/Macros/FixturePlugin")
            .appendingPathComponent(macroKey.calculateChecksum())
            .appendingPathComponent("FixturePlugin/FixturePlugin")
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
                .product(name: "FixtureLibrary", package: "MacroFixture")
            ])])
        """.write(to: parent.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        try await runner.run(packageDirectory: parent, frameworkOutputDir: .custom(output))
        #expect(manager.fileExists(atPath: framework.path))
        #expect(!manager.fileExists(atPath: version.path))
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
