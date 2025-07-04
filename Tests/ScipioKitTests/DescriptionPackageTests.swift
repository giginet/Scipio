import Foundation
@testable import ScipioKit
import XCTest

private let fixturePath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources")
    .appendingPathComponent("Fixtures")

final class DescriptionPackageTests: XCTestCase {
    func testDescriptionPackage() async throws {
        let rootPath = fixturePath.appendingPathComponent("TestingPackage")
        let package = try await DescriptionPackage(
            packageDirectory: rootPath,
            mode: .prepareDependencies,
            onlyUseVersionsFromResolvedFile: false
        )
        XCTAssertEqual(package.name, "TestingPackage")

        let packageNames = package.graph.allPackages.map(\.value.manifest.name)
        XCTAssertEqual(packageNames.sorted(), ["TestingPackage", "swift-log"].sorted())

        XCTAssertEqual(
            package.workspaceDirectory.path(percentEncoded: false),
            rootPath.appendingPathComponent(".build/scipio").path
        )

        XCTAssertEqual(
            package.derivedDataPath.path(percentEncoded: false),
            rootPath.appendingPathComponent(".build/scipio/DerivedData").path
        )
    }

    func testBuildProductsInPrepareMode() async throws {
        let rootPath = fixturePath.appendingPathComponent("IntegrationTestPackage")
        let package = try await DescriptionPackage(
            packageDirectory: rootPath,
            mode: .prepareDependencies,
            onlyUseVersionsFromResolvedFile: false
        )
        XCTAssertEqual(package.name, "IntegrationTestPackage")

        XCTAssertEqual(
            try package.resolveBuildProductDependencyGraph().allNodes.map(\.value.target.name).sorted(),
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

    func testBuildProductsInCreateMode() async throws {
        let rootPath = fixturePath.appendingPathComponent("TestingPackage")
        let package = try await DescriptionPackage(
            packageDirectory: rootPath,
            mode: .createPackage,
            onlyUseVersionsFromResolvedFile: false
        )
        XCTAssertEqual(package.name, "TestingPackage")

        let graph = try package.resolveBuildProductDependencyGraph()
            .map { $0.target.name }

        let myTargetNode = try XCTUnwrap(graph.rootNodes.first)
        XCTAssertEqual(myTargetNode.value, "MyTarget")

        let loggingTargetNode = try XCTUnwrap(myTargetNode.children.first)
        XCTAssertEqual(loggingTargetNode.value, "Logging")

        XCTAssertNil(loggingTargetNode.children.first)
    }

    func testBinaryBuildProductsInCreateMode() async throws {
        let rootPath = fixturePath.appendingPathComponent("BinaryPackage")
        let package = try await DescriptionPackage(
            packageDirectory: rootPath,
            mode: .createPackage,
            onlyUseVersionsFromResolvedFile: false
        )
        XCTAssertEqual(package.name, "BinaryPackage")
        XCTAssertEqual(
            Set(try package.resolveBuildProductDependencyGraph().allNodes.map(\.value.target.name)),
            ["SomeBinary"]
        )
    }
}
