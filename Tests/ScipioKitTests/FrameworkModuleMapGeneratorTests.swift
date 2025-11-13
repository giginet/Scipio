import Foundation
@testable import ScipioKit
import Testing

private let fixturesPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources")
    .appendingPathComponent("Fixtures")
private let clangPackageWithUmbrellaDirectoryPath = fixturesPath.appendingPathComponent("ClangPackageWithUmbrellaDirectory")
private let clangPackageWithRelativePublicHeadersPath = fixturesPath.appendingPathComponent("ClangPackageWithRelativePublicHeadersPath")

private struct PackageLocatorMock: PackageLocator {
    let packageDirectory: URL
}

@Suite(.serialized)
struct FrameworkModuleMapGeneratorTests {
    let fileSystem: LocalFileSystem = .default
    let temporaryDirectory: URL

    init() {
        self.temporaryDirectory = fileSystem
            .tempDirectory
            .appending(components: "FrameworkModuleMapGeneratorTests")
    }

    @Test
    func generate_keepPublicHeadersStructure_is_false() async throws {
        let outputDirectory = temporaryDirectory.appending(component: #function)
        defer { try? fileSystem.removeFileTree(outputDirectory) }

        let generatedModuleMapContents = try await generateModuleMap(
            for: clangPackageWithUmbrellaDirectoryPath,
            moduleName: "MyTarget",
            keepPublicHeadersStructure: false,
            outputDirectory: outputDirectory
        )
        let expectedModuleMapContents = """
framework module MyTarget {
    header "a.h"
    header "add.h"
    header "b.h"
    header "c.h"
    header "my_target.h"
    export *
}
"""
        #expect(generatedModuleMapContents == expectedModuleMapContents)
    }

    @Test
    func generate_keepPublicHeadersStructure_is_true() async throws {
        let outputDirectory = temporaryDirectory.appending(component: #function)
        defer { try? fileSystem.removeFileTree(outputDirectory) }

        let generatedModuleMapContents = try await generateModuleMap(
            for: clangPackageWithUmbrellaDirectoryPath,
            moduleName: "MyTarget",
            keepPublicHeadersStructure: true,
            outputDirectory: outputDirectory
        )
        let expectedModuleMapContents = """
framework module MyTarget {
    header "a.h"
    header "add.h"
    header "b.h"
    header "my_target.h"
    header "subdir/c.h"
    export *
}
"""
        #expect(generatedModuleMapContents == expectedModuleMapContents)
    }

    @Test
    func generate_keepPublicHeadersStructure_is_true_withRelativePublicHeadersPath() async throws {
        let outputDirectory = temporaryDirectory.appending(component: #function)
        defer { try? fileSystem.removeFileTree(outputDirectory) }

        let generatedModuleMapContents = try await generateModuleMap(
            for: clangPackageWithRelativePublicHeadersPath,
            moduleName: "ClangPackageWithRelativePublicHeadersPath",
            keepPublicHeadersStructure: true,
            outputDirectory: outputDirectory
        )
        let expectedModuleMapContents = """
framework module ClangPackageWithRelativePublicHeadersPath {
    header "ClangPackageWithRelativePublicHeadersPath/add.h"
    export *
}
"""
        #expect(generatedModuleMapContents == expectedModuleMapContents)
    }

    private func generateModuleMap(
        for packageDirectory: URL,
        moduleName: String,
        keepPublicHeadersStructure: Bool,
        outputDirectory: URL
    ) async throws -> String {
        let packageLocator = PackageLocatorMock(packageDirectory: outputDirectory)
        let generator = FrameworkModuleMapGenerator(
            packageLocator: packageLocator,
            fileSystem: fileSystem
        )

        let descriptionPackage = try await DescriptionPackage(
            packageDirectory: packageDirectory,
            mode: .createPackage,
            resolvedPackagesCachePolicies: [],
            onlyUseVersionsFromResolvedFile: false
        )
        let generatedModuleMapPath = try generator.generate(
            resolvedTarget: #require(descriptionPackage.graph.module(for: moduleName)),
            sdk: SDK.macOS,
            keepPublicHeadersStructure: keepPublicHeadersStructure
        )

        let generatedModuleMapData = try Data(contentsOf: #require(generatedModuleMapPath))
        let generatedModuleMapContents = String(decoding: generatedModuleMapData, as: UTF8.self)
        return generatedModuleMapContents
    }
}
