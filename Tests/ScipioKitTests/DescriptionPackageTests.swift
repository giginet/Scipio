import Foundation
import Testing
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
}
