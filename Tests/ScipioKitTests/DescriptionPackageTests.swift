import Foundation
@testable import ScipioKit
import Testing

private let fixturePath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources")
    .appendingPathComponent("Fixtures")

@Suite
struct DescriptionPackageTests {
    @Test
    func descriptionPackage() async throws {
        let rootPath = fixturePath.appendingPathComponent("TestingPackage")
        let package = try await DescriptionPackage(
            packageDirectory: rootPath.absolutePath,
            mode: .prepareDependencies,
            onlyUseVersionsFromResolvedFile: false
        )
        #expect(package.name == "TestingPackage")

        let packageNames = package.graph.packages.map(\.manifest.displayName)
        #expect(packageNames.sorted() == ["TestingPackage", "swift-log"].sorted())

        #expect(
            package.workspaceDirectory.pathString == rootPath.appendingPathComponent(".build/scipio").path
        )

        #expect(
            package.derivedDataPath.pathString == rootPath.appendingPathComponent(".build/scipio/DerivedData").path
        )
    }

    @Test
    func buildProductsInPrepareMode() async throws {
        let rootPath = fixturePath.appendingPathComponent("IntegrationTestPackage")
        let package = try await DescriptionPackage(
            packageDirectory: rootPath.absolutePath,
            mode: .prepareDependencies,
            onlyUseVersionsFromResolvedFile: false
        )
        #expect(package.name == "IntegrationTestPackage")

        #expect(
            try package.resolveBuildProductDependencyGraph().allNodes.map(\.value.target.name).sorted() == [
                "Atomics",
                "CNIOAtomics",
                "CNIODarwin",
                "CNIOLinux",
                "CNIOWindows",
                "DequeModule",
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
                "_NIODataStructures",
            ]
        )
    }

    @Test
    func buildProductsInCreateMode() async throws {
        let rootPath = fixturePath.appendingPathComponent("TestingPackage")
        let package = try await DescriptionPackage(
            packageDirectory: rootPath.absolutePath,
            mode: .createPackage,
            onlyUseVersionsFromResolvedFile: false
        )
        #expect(package.name == "TestingPackage")

        let graph = try package.resolveBuildProductDependencyGraph()
            .map { $0.target.name }

        let myPluginNode = try #require(graph.rootNodes.first)
        #expect(myPluginNode.value == "MyPlugin")

        let executableTargetNode = try #require(myPluginNode.children.first)
        #expect(executableTargetNode.value == "ExecutableTarget")

        let myTargetNode = try #require(executableTargetNode.children.first)
        #expect(myTargetNode.value == "MyTarget")

        let loggingNode = try #require(myTargetNode.children.first)
        #expect(loggingNode.value == "Logging")
    }

    @Test
    func binaryBuildProductsInCreateMode() async throws {
        let rootPath = fixturePath.appendingPathComponent("BinaryPackage")
        let package = try await DescriptionPackage(
            packageDirectory: rootPath.absolutePath,
            mode: .createPackage,
            onlyUseVersionsFromResolvedFile: false
        )
        #expect(package.name == "BinaryPackage")
        #expect(
            Set(try package.resolveBuildProductDependencyGraph().allNodes.map(\.value.target.name)) == ["SomeBinary"]
        )
    }
}
