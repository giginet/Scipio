import CacheStorage
import CryptoKit
import Foundation
import PackageManifestKit
import Testing
@testable import ScipioKit

struct MacroCacheTests {
    @Test(arguments: [
        (SDK.macOS, "macos"), (SDK.macCatalyst, "maccatalyst"),
        (SDK.iOS, "ios"), (SDK.iOSSimulator, "ios"),
        (SDK.tvOS, "tvos"), (SDK.tvOSSimulator, "tvos"),
        (SDK.watchOS, "watchos"), (SDK.watchOSSimulator, "watchos"),
        (SDK.visionOS, "visionos"), (SDK.visionOSSimulator, "visionos"),
    ], [false, true])
    func conditionalMacrosMatchDestination(destination: (sdk: SDK, platform: String), usesProduct: Bool) throws {
        let selected = try ResolvedGraphFixtures.resolvedModule(name: "SelectedPlugin", targetType: "macro")
        let linuxOnly = try ResolvedGraphFixtures.resolvedModule(name: "LinuxOnlyPlugin", targetType: "macro")
        let other = try ResolvedGraphFixtures.resolvedModule(name: "OtherPlugin", targetType: "macro")
        let unconditional = try ResolvedGraphFixtures.resolvedModule(name: "AlwaysPlugin", targetType: "macro")
        let specifications: [(ResolvedModule, [PackageCondition])] = [
            (selected, [.init(platformNames: [destination.platform])]),
            (linuxOnly, [.init(platformNames: ["linux"])]),
            (other, [.init(platformNames: [destination.platform == "macos" ? "ios" : "macos"])]),
            (unconditional, []),
        ]
        let dependencies = try specifications.map { module, conditions -> ResolvedModule.Dependency in
            if usesProduct {
                return .product(
                    try ResolvedGraphFixtures.resolvedProduct(name: "\(module.name)Product", modules: [module]), conditions: conditions
                )
            }
            return .module(module, conditions: conditions)
        }
        let library = try ResolvedGraphFixtures.resolvedModule(name: "Library", dependencies: dependencies)
        let package = try ResolvedGraphFixtures.package(targets: [library, selected, linuxOnly, other, unconditional])
        let graph = try DependencyGraph.resolve(
            Set([BuildProduct(package: package, target: library)]), id: \.target.name, childIDs: { _ in [] }
        )

        let plan = try MacroBuildPlan(graph: graph, buildOptions: makeBuildOptions(sdks: [destination.sdk]))

        #expect(plan.modules.map(\.name) == ["AlwaysPlugin", "SelectedPlugin"])
        #expect(plan.targetDependencies == ["Library": ["AlwaysPlugin", "SelectedPlugin"]])
        #expect(plan.hostOnlyDependencies["Library"]?.contains("LinuxOnlyPlugin") == true)
        #expect(plan.hostOnlyDependencies["Library"]?.contains("OtherPlugin") == true)
    }

    @Test(arguments: [BuildConfiguration.debug, .release], [false, true])
    func conditionalMacrosMatchTargetConfiguration(configuration: BuildConfiguration, usesOverride: Bool) throws {
        let plugin = try ResolvedGraphFixtures.resolvedModule(name: "ReleasePlugin", targetType: "macro")
        let library = try ResolvedGraphFixtures.resolvedModule(
            name: "Library", dependencies: [.module(plugin, conditions: [.init(platformNames: ["ios"], config: "release")])]
        )
        let package = try ResolvedGraphFixtures.package(targets: [library, plugin])
        let graph = try DependencyGraph.resolve(
            Set([BuildProduct(package: package, target: library)]), id: \.target.name, childIDs: { _ in [] }
        )
        let options = makeBuildOptions(configuration: configuration)

        let plan = try MacroBuildPlan(
            graph: graph, buildOptions: usesOverride ? makeBuildOptions(sdks: [.macOS]) : options,
            buildOptionsMatrix: usesOverride ? ["Library": options] : [:]
        )

        #expect(plan.modules.map(\.name) == (configuration == .release ? ["ReleasePlugin"] : []))
        #expect(plan.targetDependencies["Library"] == (configuration == .release ? ["ReleasePlugin"] : nil))
        #expect(plan.hostOnlyDependencies["Library"] == ["ReleasePlugin"])
    }

    @Test(arguments: [BuildConfiguration.debug, .release])
    func conditionalRuntimeDependenciesPreserveHostOnlyClassification(configuration: BuildConfiguration) throws {
        let shared = try ResolvedGraphFixtures.resolvedModule(name: "Shared")
        let plugin = try ResolvedGraphFixtures.resolvedModule(
            name: "Plugin", targetType: "macro", dependencies: [.module(shared, conditions: [])]
        )
        let bridge = try ResolvedGraphFixtures.resolvedModule(
            name: "Bridge", dependencies: [.module(shared, conditions: [.init(config: "release")])]
        )
        let library = try ResolvedGraphFixtures.resolvedModule(
            name: "Library", dependencies: [.module(plugin, conditions: []), .module(bridge, conditions: [])]
        )
        let package = try ResolvedGraphFixtures.package(targets: [library, plugin, bridge, shared])
        let graph = try DependencyGraph.resolve(
            Set([BuildProduct(package: package, target: library)]), id: \.target.name, childIDs: { _ in [] }
        )

        let plan = try MacroBuildPlan(graph: graph, buildOptions: makeBuildOptions(configuration: configuration))

        #expect(plan.hostOnlyDependencies["Library"] == (configuration == .release ? ["Plugin"] : ["Plugin", "Shared"]))
    }

    @Test
    func conditionalMacrosCoverAllRequestedDestinations() throws {
        let ios = try ResolvedGraphFixtures.resolvedModule(name: "IOSPlugin", targetType: "macro")
        let macos = try ResolvedGraphFixtures.resolvedModule(name: "MacPlugin", targetType: "macro")
        let impossible = try ResolvedGraphFixtures.resolvedModule(name: "ImpossiblePlugin", targetType: "macro")
        let library = try ResolvedGraphFixtures.resolvedModule(name: "Library", dependencies: [
            .module(ios, conditions: [.init(platformNames: ["ios"])]),
            .module(macos, conditions: [.init(platformNames: ["macos"])]),
            .module(impossible, conditions: [.init(platformNames: ["ios"]), .init(platformNames: ["macos"])]),
        ])
        let package = try ResolvedGraphFixtures.package(targets: [library, ios, macos, impossible])
        let graph = try DependencyGraph.resolve(
            Set([BuildProduct(package: package, target: library)]), id: \.target.name, childIDs: { _ in [] }
        )

        let plan = try MacroBuildPlan(graph: graph, buildOptions: makeBuildOptions(sdks: [.iOS, .macOS]))

        #expect(plan.modules.map(\.name) == ["IOSPlugin", "MacPlugin"])
        #expect(plan.targetDependencies == ["Library": ["IOSPlugin", "MacPlugin"]])
    }

    @Test(arguments: [false, true], [false, true])
    func runtimeTraversalStopsAtSharedMacroTargets(usesProduct: Bool, sharesRuntimeDependency: Bool) throws {
        let hostSupport = try ResolvedGraphFixtures.resolvedModule(name: "HostSupport")
        let sharedSupport = try ResolvedGraphFixtures.resolvedModule(name: "SharedSupport")
        let plugin = try ResolvedGraphFixtures.resolvedModule(
            name: "Plugin", targetType: "macro",
            dependencies: [.module(hostSupport, conditions: []), .module(sharedSupport, conditions: [])]
        )
        let library = try ResolvedGraphFixtures.resolvedModule(
            name: "Library",
            dependencies: [.module(plugin, conditions: [])] + (sharesRuntimeDependency ? [.module(sharedSupport, conditions: [])] : [])
        )
        let libraryDependency: ResolvedModule.Dependency
        if usesProduct {
            libraryDependency = .product(
                try ResolvedGraphFixtures.resolvedProduct(name: "LibraryProduct", modules: [library]), conditions: []
            )
        } else {
            libraryDependency = .module(library, conditions: [])
        }
        let consumer = try ResolvedGraphFixtures.resolvedModule(
            name: "Consumer", dependencies: [.module(plugin, conditions: []), libraryDependency]
        )
        let package = try ResolvedGraphFixtures.package(targets: [consumer, library, plugin, hostSupport, sharedSupport])
        let products = Set([consumer, library].map { BuildProduct(package: package, target: $0) })
        let productNames = Set(products.map(\.target.name))
        let graph = try DependencyGraph.resolve(
            products, id: \.target.name,
            childIDs: { $0.target.dependencies.flatMap(\.modules).map(\.name).filter(productNames.contains) }
        )

        let plan = try MacroBuildPlan(graph: graph, buildOptions: makeBuildOptions())

        let expectedHostOnly: Set<String> = sharesRuntimeDependency ? ["Plugin", "HostSupport"] : ["Plugin", "HostSupport", "SharedSupport"]
        #expect(plan.hostOnlyDependencies["Consumer"] == expectedHostOnly)
        #expect(plan.hostOnlyDependencies["Library"] == expectedHostOnly)
        #expect(plan.targetDependencies == ["Consumer": ["Plugin"], "Library": ["Plugin"]])
        #expect(plan.modules.map(\.name) == ["Plugin"])
    }

    private func key(
        revision: String = "123", swiftVersion: String = "Swift 6", schemaVersion: Int = 1,
        configuration: BuildConfiguration = .debug
    ) -> MacroCacheKey {
        MacroCacheKey(
            schemaVersion: schemaVersion, artifactKind: .macroPlugin, targetName: "ExamplePlugin",
            dependencies: [
                .init(
                    packageIdentity: "example",
                    pin: .sourceControl(revision: revision),
                    targetName: "ExamplePlugin"
                ),
            ],
            swiftVersion: swiftVersion, clangVersion: "Clang", xcodeVersion: "Xcode",
            hostArchitecture: "arm64", deploymentTarget: nil, rootMacOSPlatform: nil, configuration: configuration,
            scipioVersion: "Scipio"
        )
    }

    private func makeBuildOptions(sdks: Set<SDK> = [.iOS], configuration: BuildConfiguration = .debug) -> BuildOptions {
        BuildOptions(
            buildConfiguration: configuration, isDebugSymbolsEmbedded: false, frameworkType: .static,
            sdks: sdks, extraFlags: nil, extraBuildParameters: nil, enableLibraryEvolution: false,
            keepPublicHeadersStructure: false, customFrameworkModuleMapContents: nil, stripStaticDWARFSymbols: false
        )
    }

    @Test func macroKeyIncludesSourceAndToolchain() throws {
        let original = key()
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(MacroCacheKey.self, from: data) == original)
        #expect(try original.calculateChecksum() != key(revision: "456").calculateChecksum())
        #expect(try original.calculateChecksum() != key(swiftVersion: "Swift 7").calculateChecksum())
    }

    @Test(.temporaryDirectory)
    func localMacroArtifactRoundTripPreservesExecutable() async throws {
        let manager = FileManager.default
        let root = TemporaryDirectory.url
        let source = root.appending(path: "source")
        let destination = root.appending(path: "restored")
        try manager.createDirectory(at: source, withIntermediateDirectories: true)
        let executable = source.appending(path: "ExamplePlugin")
        try Data("plugin".utf8).write(to: executable)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let storage = LocalDiskCacheStorage(baseURL: root)
        let key = key()

        #expect(try await !storage.existsArtifact(for: key, kind: .macroPlugin))
        try await storage.cacheArtifact(source, for: key, kind: .macroPlugin)
        #expect(try await storage.existsArtifact(for: key, kind: .macroPlugin))
        try await storage.fetchArtifact(for: key, kind: .macroPlugin, to: destination)
        let restored = destination.appending(path: "ExamplePlugin")
        #expect(try Data(contentsOf: restored) == Data("plugin".utf8))
        #expect(manager.isExecutableFile(atPath: restored.path))
        let cachePath = try root.appending(
            components: "Scipio", "Macros", "ExamplePlugin", key.calculateChecksum(), "ExamplePlugin", "ExamplePlugin"
        )
        #expect(manager.fileExists(atPath: cachePath.path))
    }

    @Test(.temporaryDirectory)
    func consumerOnlyPolicyPreservesInvalidCache() async throws {
        try await invalidCacheFallsBackToNextStorage(canProduce: false)
    }

    @Test(.temporaryDirectory)
    func producerPolicyRepairsInvalidCache() async throws {
        try await invalidCacheFallsBackToNextStorage(canProduce: true)
    }

    private func invalidCacheFallsBackToNextStorage(canProduce: Bool) async throws {
        let manager = FileManager.default
        let root = TemporaryDirectory.url
        let packageDirectory = root.appending(path: "Package")
        try manager.createDirectory(at: packageDirectory.appending(path: "Sources/Library"), withIntermediateDirectories: true)
        try manager.createDirectory(at: packageDirectory.appending(path: "Sources/ExamplePlugin"), withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        import CompilerPluginSupport
        let package = Package(name: "Fixture", products: [.library(name: "Library", targets: ["Library"])],
            targets: [.macro(name: "ExamplePlugin"), .target(name: "Library", dependencies: ["ExamplePlugin"])])
        """.write(to: packageDirectory.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
        try "public struct Library {}".write(
            to: packageDirectory.appending(path: "Sources/Library/Library.swift"), atomically: true, encoding: .utf8
        )
        try "@main struct Plugin { static func main() {} }".write(
            to: packageDirectory.appending(path: "Sources/ExamplePlugin/Plugin.swift"), atomically: true, encoding: .utf8
        )
        let package = try await DescriptionPackage(
            packageDirectory: packageDirectory, mode: .createPackage,
            resolvedPackagesCachePolicies: [], onlyUseVersionsFromResolvedFile: false
        )
        let plan = try MacroBuildPlan(graph: package.resolveBuildProductDependencyGraph(), buildOptions: makeBuildOptions())
        let output = root.appending(path: "output")
        let artifact = root.appending(path: "artifact")
        try manager.createDirectory(at: artifact, withIntermediateDirectories: true)
        let executable = artifact.appending(path: "ExamplePlugin")
        let contents = Data("plugin".utf8)
        try contents.write(to: executable)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let invalidStorage = LocalDiskCacheStorage(baseURL: root.appending(path: "invalid"))
        let fallbackStorage = LocalDiskCacheStorage(baseURL: root.appending(path: "fallback"))
        let key = key()
        try await invalidStorage.cacheArtifact(artifact, for: key, kind: .macroPlugin)
        let checksum = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
        try JSONSerialization.data(withJSONObject: [
            "executable": "ExamplePlugin", "files": ["ExamplePlugin": checksum],
        ]).write(to: artifact.appending(path: "artifact.json"))
        try await fallbackStorage.cacheArtifact(artifact, for: key, kind: .macroPlugin)
        let executor = StubbableExecutor { _ in throw MacroPluginProducer.Error.missingExecutable("Unexpected build") }
        let producer = MacroPluginProducer(
            package: package, outputDirectory: output, destinationSDK: .macOS,
            policies: [
                .init(storage: invalidStorage, actors: canProduce ? [.consumer, .producer] : [.consumer]),
                .init(storage: fallbackStorage, actors: [.consumer]),
            ], executor: executor
        )
        let plugin = MacroPlugin(
            targetName: "ExamplePlugin", moduleName: "ExamplePlugin",
            executable: output.appending(components: "ExamplePlugin", "ExamplePlugin"), cacheKey: key
        )

        try await producer.produce(plan, plugins: ["ExamplePlugin": plugin])

        #expect(try Data(contentsOf: plugin.executable) == contents)
        #expect(try MacroVersionFileDecoder().decode(versionFile: output.appending(path: ".ExamplePlugin.version")) == key)
        #expect(try manager.contentsOfDirectory(atPath: output.path).allSatisfy { !$0.hasPrefix(".restore-") })
        let stored = root.appending(path: "stored")
        #expect(try await invalidStorage.existsArtifact(for: key, kind: .macroPlugin))
        try await invalidStorage.fetchArtifact(for: key, kind: .macroPlugin, to: stored)
        #expect(manager.fileExists(atPath: stored.appending(path: "artifact.json").path) == canProduce)
        #expect(await executor.calledCount == 0)
    }

    @Test(.temporaryDirectory, arguments: ["debug", "release"])
    func configurationPreservesVersionFileAndChecksum(configuration: String) throws {
        let legacyData = Data("""
        {
          "schemaVersion": 1,
          "artifactKind": "macroPlugin",
          "targetName": "ExamplePlugin",
          "dependencies": [{
            "packageIdentity": "example",
            "pin": {"kind": "sourceControl", "revision": "123"},
            "targetName": "ExamplePlugin"
          }],
          "swiftVersion": "Swift 6",
          "clangVersion": "Clang",
          "xcodeVersion": "Xcode",
          "hostArchitecture": "arm64",
          "configuration": "\(configuration)",
          "scipioVersion": "Scipio"
        }
        """.utf8)
        let versionFile = TemporaryDirectory.url.appending(path: ".ExamplePlugin.version")
        try legacyData.write(to: versionFile)

        let decoded = try MacroVersionFileDecoder().decode(versionFile: versionFile)

        let expectedConfiguration = try #require(BuildConfiguration(rawValue: configuration))
        #expect(decoded == key(configuration: expectedConfiguration))
        let canonicalLegacyData = try JSONSerialization.data(
            withJSONObject: JSONSerialization.jsonObject(with: legacyData), options: [.prettyPrinted, .sortedKeys]
        )
        let legacyChecksum = SHA256.hash(data: canonicalLegacyData).map { String(format: "%02x", $0) }.joined()
        #expect(try decoded.calculateChecksum() == legacyChecksum)
    }

    @Test(.temporaryDirectory)
    func versionDecoderRejectsUnknownSchema() throws {
        let url = TemporaryDirectory.url.appending(path: ".ExamplePlugin.version")
        try JSONEncoder().encode(key()).write(to: url)
        #expect(try MacroVersionFileDecoder().decode(versionFile: url) == key())
        try JSONEncoder().encode(key(schemaVersion: 99)).write(to: url)
        #expect(throws: MacroVersionFileDecoder.Error.self) {
            try MacroVersionFileDecoder().decode(versionFile: url)
        }
    }
}
