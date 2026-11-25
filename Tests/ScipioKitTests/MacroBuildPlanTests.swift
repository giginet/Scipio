import CacheStorage
import Foundation
import PackageManifestKit
import enum PIFKit.PIFDependency
import Testing
@testable import ScipioKit

struct MacroBuildPlanTests {
    @Test("Host and runtime dependencies distinguish products from same-named targets", arguments: [false, true])
    func sameNamedTargetAndProduct(hostUsesProduct: Bool) throws {
        let shared = try ResolvedGraphFixtures.resolvedModule(name: "Shared")
        let support = try ResolvedGraphFixtures.resolvedModule(
            name: "Support", packageID: ResolvedGraphFixtures.packageID("support-package")
        )
        let product = try ResolvedGraphFixtures.resolvedProduct(name: "Shared", modules: [support], packageID: support.packageID)
        let hostDependency: ResolvedModule.Dependency = hostUsesProduct
            ? .product(product, conditions: []) : .module(shared, conditions: [])
        let runtimeDependency: ResolvedModule.Dependency = hostUsesProduct
            ? .module(shared, conditions: []) : .product(product, conditions: [])
        let plugin = try ResolvedGraphFixtures.resolvedModule(name: "Plugin", targetType: "macro", dependencies: [hostDependency])
        let client = try ResolvedGraphFixtures.resolvedModule(
            name: "Client", dependencies: [runtimeDependency, .module(plugin, conditions: [])]
        )
        let clientProduct = try ResolvedGraphFixtures.resolvedProduct(name: "PublicClient", modules: [client])
        let package = try ResolvedGraphFixtures.package(targets: [client, plugin, shared], products: [clientProduct])
        let graph = try DependencyGraph.resolve(Set([BuildProduct(package: package, target: client)]), id: \.target.name, childIDs: { _ in [] })

        let plan = try MacroBuildPlan(graph: graph, buildOptions: makeBuildOptions())

        let expected: Set<PIFDependency> = hostUsesProduct
            ? [.target("Plugin"), .product("Shared"), .target("Support")]
            : [.target("Plugin"), .target("Shared")]
        #expect(plan.hostOnlyDependencies["Client"] == expected)
        #expect(plan.hostOnlyProductDependencies["PublicClient"] == expected)
    }

    @Test("Product cleanup uses its actual modules and preserves shared runtime dependencies", arguments: [false, true])
    func productModulesPreserveRuntimeDependencies(sharesRuntimeDependency: Bool) throws {
        let support = try ResolvedGraphFixtures.resolvedModule(name: "HostSupport")
        let plugin = try ResolvedGraphFixtures.resolvedModule(
            name: "Plugin", targetType: "macro", dependencies: [.module(support, conditions: [])]
        )
        let declarations = try ResolvedGraphFixtures.resolvedModule(name: "Declarations", dependencies: [.module(plugin, conditions: [])])
        let runtime = try ResolvedGraphFixtures.resolvedModule(
            name: "Runtime", dependencies: sharesRuntimeDependency ? [.module(support, conditions: [])] : []
        )
        let product = try ResolvedGraphFixtures.resolvedProduct(name: "PublicDeclarations", modules: [declarations, runtime])
        let client = try ResolvedGraphFixtures.resolvedModule(name: "Client", dependencies: [.product(product, conditions: [])])
        let package = try ResolvedGraphFixtures.package(targets: [client, declarations, runtime, support, plugin], products: [product])
        let graph = try DependencyGraph.resolve(
            Set([client, declarations, runtime].map { BuildProduct(package: package, target: $0) }), id: \.target.name, childIDs: { _ in [] }
        )

        let plan = try MacroBuildPlan(graph: graph, buildOptions: makeBuildOptions())

        #expect(plan.hostOnlyDependencies["Declarations"] == [.target("Plugin"), .target("HostSupport")])
        let expected: Set<PIFDependency> = sharesRuntimeDependency
            ? [.target("Plugin")] : [.target("Plugin"), .target("HostSupport")]
        #expect(plan.hostOnlyProductDependencies == ["PublicDeclarations": expected])
    }

    @Test("Public macros are loaded through enabled transitive target and product dependencies", arguments: [false, true])
    func transitiveMacros(usesProduct: Bool) throws {
        let hostOnly = try ResolvedGraphFixtures.resolvedModule(name: "HostPlugin", targetType: "macro")
        let plugin = try ResolvedGraphFixtures.resolvedModule(
            name: "Plugin", targetType: "macro", dependencies: [.module(hostOnly, conditions: [])]
        )
        let declarations = try ResolvedGraphFixtures.resolvedModule(name: "Declarations", dependencies: [.module(plugin, conditions: [])])
        let dependency: ResolvedModule.Dependency = usesProduct
            ? .product(try ResolvedGraphFixtures.resolvedProduct(name: "PublicDeclarations", modules: [declarations]), conditions: [])
            : .module(declarations, conditions: [])
        let client = try ResolvedGraphFixtures.resolvedModule(name: "Client", dependencies: [dependency])
        let package = try ResolvedGraphFixtures.package(targets: [client, declarations, plugin, hostOnly])
        let graph = try DependencyGraph.resolve(Set([BuildProduct(package: package, target: client)]), id: \.target.name, childIDs: { _ in [] })

        let plan = try MacroBuildPlan(graph: graph, buildOptions: makeBuildOptions())

        #expect(plan.modules.map(\.name) == ["Plugin"])
        #expect(plan.targetDependencies == ["Client": ["Plugin"]])
        #expect(plan.hostOnlyDependencies["Client"] == [.target("Plugin"), .target("HostPlugin")])
    }

    @Test("Transitive macro paths must be enabled for the same destination", arguments: [false, true])
    func transitiveMacroConditions(compatible: Bool) throws {
        let plugin = try ResolvedGraphFixtures.resolvedModule(name: "Plugin", targetType: "macro")
        let declarations = try ResolvedGraphFixtures.resolvedModule(
            name: "Declarations", dependencies: [.module(plugin, conditions: [.init(platformNames: [compatible ? "ios" : "macos"])])]
        )
        let client = try ResolvedGraphFixtures.resolvedModule(
            name: "Client", dependencies: [.module(declarations, conditions: [.init(platformNames: ["ios"], config: "release")])]
        )
        let package = try ResolvedGraphFixtures.package(targets: [client, declarations, plugin])
        let graph = try DependencyGraph.resolve(Set([BuildProduct(package: package, target: client)]), id: \.target.name, childIDs: { _ in [] })

        let debug = try MacroBuildPlan(graph: graph, buildOptions: makeBuildOptions(sdks: [.iOS, .macOS]))
        let release = try MacroBuildPlan(graph: graph, buildOptions: makeBuildOptions(sdks: [.iOS, .macOS], configuration: .release))

        #expect(debug.modules.isEmpty)
        #expect(release.targetDependencies == (compatible ? ["Client": ["Plugin"]] : [:]))
    }

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
        #expect(plan.hostOnlyDependencies["Library"]?.contains(.target("LinuxOnlyPlugin")) == true)
        #expect(plan.hostOnlyDependencies["Library"]?.contains(.target("OtherPlugin")) == true)
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
        #expect(plan.hostOnlyDependencies["Library"] == [.target("ReleasePlugin")])
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

        #expect(plan.hostOnlyDependencies["Library"] == (configuration == .release ? [.target("Plugin")] : [.target("Plugin"), .target("Shared")]))
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

        let expectedHostOnly: Set<PIFDependency> = sharesRuntimeDependency
            ? [.target("Plugin"), .target("HostSupport")]
            : [.target("Plugin"), .target("HostSupport"), .target("SharedSupport")]
        #expect(plan.hostOnlyDependencies["Consumer"] == expectedHostOnly)
        #expect(plan.hostOnlyDependencies["Library"] == expectedHostOnly)
        #expect(plan.targetDependencies == ["Consumer": ["Plugin"], "Library": ["Plugin"]])
        #expect(plan.modules.map(\.name) == ["Plugin"])
    }

    private func makeBuildOptions(sdks: Set<SDK> = [.iOS], configuration: BuildConfiguration = .debug) -> BuildOptions {
        BuildOptions(
            buildConfiguration: configuration, isDebugSymbolsEmbedded: false, frameworkType: .static,
            sdks: sdks, extraFlags: nil, extraBuildParameters: nil, enableLibraryEvolution: false,
            keepPublicHeadersStructure: false, customFrameworkModuleMapContents: nil, stripStaticDWARFSymbols: false
        )
    }

}
