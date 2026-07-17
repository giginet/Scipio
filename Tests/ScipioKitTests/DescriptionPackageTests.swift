import Foundation
import Testing
import PackageManifestKit
import ScipioKitCore
@testable import ScipioKit

private let fixturePath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources")
    .appendingPathComponent("Fixtures")

struct DescriptionPackageTests {
    @Test
    func descriptionPackage() async throws {
        let rootPath = fixturePath.appendingPathComponent("TestingPackage")
        let package = try await DescriptionPackage(
            packageDirectory: rootPath,
            mode: .prepareDependencies,
            resolvedPackagesCachePolicies: [],
            onlyUseVersionsFromResolvedFile: false
        )
        #expect(package.name == "TestingPackage")

        let packageNames = package.graph.allPackages.map(\.value.manifest.name)
        #expect(packageNames.sorted() == ["TestingPackage", "swift-log"].sorted())

        #expect(
            package.workspaceDirectory.path(percentEncoded: false) ==
            rootPath.appendingPathComponent(".build/scipio").path
        )

        #expect(
            package.derivedDataPath.path(percentEncoded: false) ==
            rootPath.appendingPathComponent(".build/scipio/DerivedData").path
        )
    }

    @Test
    func buildProductsInPrepareMode() async throws {
        let rootPath = fixturePath.appendingPathComponent("IntegrationTestPackage")
        let package = try await DescriptionPackage(
            packageDirectory: rootPath,
            mode: .prepareDependencies,
            resolvedPackagesCachePolicies: [],
            onlyUseVersionsFromResolvedFile: false
        )
        #expect(package.name == "IntegrationTestPackage")

        #expect(
            try package.resolveBuildProductDependencyGraph().allNodes.map(\.value.target.name).sorted() ==
            [
                "Atomics",
                "CNIOAtomics",
                "CNIODarwin",
                "CNIOLinux",
                "CNIOWASI",
                "CNIOWindows",
                "DequeModule",
                "InternalCollectionsUtilities",
                "Logging",
                "NIO",
                "NIOConcurrencyHelpers",
                "NIOCore",
                "NIOEmbedded",
                "NIOPosix",
                "OrderedCollections",
                "SDWebImage",
                "SDWebImageMapKit",
                "_AtomicsShims",
                "_NIOBase64",
                "_NIODataStructures",
            ]
        )
    }

    @Test
    func buildProductsInCreateMode() async throws {
        let rootPath = fixturePath.appendingPathComponent("TestingPackage")
        let package = try await DescriptionPackage(
            packageDirectory: rootPath,
            mode: .createPackage,
            resolvedPackagesCachePolicies: [],
            onlyUseVersionsFromResolvedFile: false
        )
        #expect(package.name == "TestingPackage")

        let graph = try package.resolveBuildProductDependencyGraph()
            .map { $0.target.name }

        let myTargetNode = try #require(graph.rootNodes.first)
        #expect(myTargetNode.value == "MyTarget")

        let loggingTargetNode = try #require(myTargetNode.children.first)
        #expect(loggingTargetNode.value == "Logging")

        #expect(loggingTargetNode.children.first == nil)
    }

    @Test
    func binaryBuildProductsInCreateMode() async throws {
        let rootPath = fixturePath.appendingPathComponent("BinaryPackage")
        let package = try await DescriptionPackage(
            packageDirectory: rootPath,
            mode: .createPackage,
            resolvedPackagesCachePolicies: [],
            onlyUseVersionsFromResolvedFile: false
        )
        #expect(package.name == "BinaryPackage")
        #expect(
            Set(try package.resolveBuildProductDependencyGraph().allNodes.map(\.value.target.name)) ==
            ["SomeBinary"]
        )
    }

    @Test
    func systemLibraryBuildProductsInCreateMode() async throws {
        let rootPath = fixturePath.appendingPathComponent("PackageWithSystemLibraryTarget")
        let package = try await DescriptionPackage(
            packageDirectory: rootPath,
            mode: .createPackage,
            resolvedPackagesCachePolicies: [],
            onlyUseVersionsFromResolvedFile: false
        )

        let graph = try package.resolveBuildProductDependencyGraph()
        #expect(graph.allNodes.map(\.value.target.name).sorted() == ["CoreLib", "MainLib", "SysShim"])

        let sysShim = try #require(graph.allNodes.map(\.value.target).first { $0.name == "SysShim" })
        guard case let .system(includeDir, publicHeaders, moduleMapPath) = sysShim.resolvedModuleType else {
            Issue.record("SysShim should be resolved as a system module, got \(sysShim.resolvedModuleType)")
            return
        }
        let expectedModuleDirectory = rootPath.appending(components: "Sources", "SysShim").standardizedFileURL
        #expect(includeDir.path(percentEncoded: false) == expectedModuleDirectory.path(percentEncoded: false))
        // Recursive discovery in path-sorted order: the nested header comes first.
        #expect(publicHeaders.map { $0.path(percentEncoded: false) } == [
            expectedModuleDirectory.appending(components: "nested", "extra.h").path(percentEncoded: false),
            expectedModuleDirectory.appending(component: "shim.h").path(percentEncoded: false),
        ])
        #expect(moduleMapPath.path(percentEncoded: false) ==
                expectedModuleDirectory.appending(component: "module.modulemap").path(percentEncoded: false))
    }

    @Test
    func executableTargetIsExcludedFromBuildProducts() async throws {
        let rootPath = fixturePath.appendingPathComponent("PackageWithExecutableTargetDependency")
        let package = try await DescriptionPackage(
            packageDirectory: rootPath,
            mode: .createPackage,
            resolvedPackagesCachePolicies: [],
            onlyUseVersionsFromResolvedFile: false
        )

        let graph = try package.resolveBuildProductDependencyGraph()
            .map { $0.target.name }

        // HelperTool produces no framework, so it is pruned together with
        // ToolSupport, which is reachable only through it.
        #expect(graph.allNodes.map(\.value) == ["MyLib"])
        let myLibNode = try #require(graph.rootNodes.first { $0.value == "MyLib" })
        #expect(myLibNode.children.isEmpty)
    }

    @Test
    func frameworkLinkableDependencies() async throws {
        let rootPath = fixturePath.appendingPathComponent("PackageWithExecutableTargetDependency")
        let package = try await DescriptionPackage(
            packageDirectory: rootPath,
            mode: .createPackage,
            resolvedPackagesCachePolicies: [],
            onlyUseVersionsFromResolvedFile: false
        )

        let myLib = try #require(package.graph.rootPackage.targets.first { $0.name == "MyLib" })

        // The executable and everything reachable only through it build no
        // framework, so nothing is linkable.
        #expect(myLib.recursiveFrameworkLinkableDependencies().isEmpty)
    }

    @Test
    func frameworkLinkableDependenciesSkipSystemModules() async throws {
        let rootPath = fixturePath.appendingPathComponent("PackageWithSystemLibraryTarget")
        let package = try await DescriptionPackage(
            packageDirectory: rootPath,
            mode: .createPackage,
            resolvedPackagesCachePolicies: [],
            onlyUseVersionsFromResolvedFile: false
        )

        let mainLib = try #require(package.graph.rootPackage.targets.first { $0.name == "MainLib" })

        // The system-library module is packaged but resolves through the SDK.
        #expect(mainLib.recursiveFrameworkLinkableDependencies().flatMap(\.moduleNames) == ["CoreLib"])
    }

    @Test
    func frameworkProducibleTargetKinds() {
        #expect(Target.TargetKind.regular.isFrameworkProducible)
        #expect(Target.TargetKind.binary.isFrameworkProducible)
        #expect(Target.TargetKind.system.isFrameworkProducible)
        #expect(!Target.TargetKind.executable.isFrameworkProducible)
        #expect(!Target.TargetKind.test.isFrameworkProducible)
        #expect(!Target.TargetKind.plugin.isFrameworkProducible)
        #expect(!Target.TargetKind.macro.isFrameworkProducible)

        // Producible but header-only: nothing to link.
        #expect(Target.TargetKind.regular.isFrameworkLinkable)
        #expect(Target.TargetKind.binary.isFrameworkLinkable)
        #expect(!Target.TargetKind.system.isFrameworkLinkable)
        #expect(!Target.TargetKind.executable.isFrameworkLinkable)
    }

    @Test
    func staleSystemModuleDetection() async throws {
        let rootPath = fixturePath.appendingPathComponent("PackageWithSystemLibraryTarget")
        let package = try await DescriptionPackage(
            packageDirectory: rootPath,
            mode: .createPackage,
            resolvedPackagesCachePolicies: [],
            onlyUseVersionsFromResolvedFile: false
        )

        let modules = package.graph.allModules
        #expect(!PackageResolver.containsStaleSystemModule(in: modules))

        // A cache written without system-library support carries the old clang fallback type.
        var staleModule = try #require(modules.first { $0.name == "SysShim" })
        staleModule.resolvedModuleType = .clang(includeDir: staleModule.localPackageURL, publicHeaders: [])
        #expect(PackageResolver.containsStaleSystemModule(in: [staleModule]))
    }
}
