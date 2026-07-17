import Foundation
@testable import ScipioKit
@testable import ScipioKitCore
import Testing

private let fixturesPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources")
    .appendingPathComponent("Fixtures")
private let clangPackageWithUmbrellaDirectoryPath = fixturesPath.appendingPathComponent("ClangPackageWithUmbrellaDirectory")
private let clangPackageWithRelativePublicHeadersPath = fixturesPath.appendingPathComponent("ClangPackageWithRelativePublicHeadersPath")
private let packageWithSystemLibraryTargetPath = fixturesPath.appendingPathComponent("PackageWithSystemLibraryTarget")

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

    @Test
    func generate_systemLibraryTarget() async throws {
        let outputDirectory = temporaryDirectory.appending(component: #function)
        defer { try? fileSystem.removeFileTree(outputDirectory) }

        let generatedModuleMapContents = try await generateModuleMap(
            for: packageWithSystemLibraryTargetPath,
            moduleName: "SysShim",
            keepPublicHeadersStructure: true,
            outputDirectory: outputDirectory
        )
        // The shipped module map is converted to a framework module; the declaration is found
        // even below leading comment lines, which stay in place.
        let expectedModuleMapContents = """
// A leading comment: the framework conversion must still find the declaration below.
framework module SysShim {
    header "shim.h"
    export *
}
"""
        #expect(generatedModuleMapContents == expectedModuleMapContents)
    }

    @Test
    func generate_skipsNonFrameworkDependenciesInLinkSection() async throws {
        let outputDirectory = temporaryDirectory.appending(component: #function)
        defer { try? fileSystem.removeFileTree(outputDirectory) }

        let executable = try ResolvedGraphFixtures.resolvedModule(
            name: "HelperTool",
            targetType: "executable"
        )
        let library = try ResolvedGraphFixtures.resolvedModule(name: "RealLib")
        let target = try ResolvedGraphFixtures.resolvedModule(
            name: "MyTarget",
            dependencies: [
                .module(executable, conditions: []),
                .module(library, conditions: []),
            ]
        )

        let generatedModuleMapContents = try await generateModuleMap(
            for: clangPackageWithUmbrellaDirectoryPath,
            moduleName: "MyTarget",
            keepPublicHeadersStructure: false,
            outputDirectory: outputDirectory,
            resolvedTarget: target
        )

        #expect(generatedModuleMapContents.contains("link framework \"RealLib\""))
        #expect(!generatedModuleMapContents.contains("link framework \"HelperTool\""))
    }

    private func generateModuleMap(
        for packageDirectory: URL,
        moduleName: String,
        keepPublicHeadersStructure: Bool,
        outputDirectory: URL,
        resolvedTarget overrideResolvedTarget: ResolvedModule? = nil
    ) async throws -> String {
        let packageLocator = PackageLocatorMock(packageDirectory: outputDirectory)
        let generator = FrameworkModuleMapGenerator(
            packageLocator: packageLocator,
            fileSystem: fileSystem
        )

        let resolvedTarget: ResolvedModule
        if let overrideResolvedTarget {
            resolvedTarget = overrideResolvedTarget
        } else {
            let descriptionPackage = try await DescriptionPackage(
                packageDirectory: packageDirectory,
                mode: .createPackage,
                resolvedPackagesCachePolicies: [],
                onlyUseVersionsFromResolvedFile: false
            )
            resolvedTarget = try #require(descriptionPackage.graph.module(for: moduleName))
        }
        let generatedModuleMapPath = try generator.generate(
            resolvedTarget: resolvedTarget,
            sdk: SDK.macOS,
            keepPublicHeadersStructure: keepPublicHeadersStructure
        )

        let generatedModuleMapData = try Data(contentsOf: #require(generatedModuleMapPath))
        let generatedModuleMapContents = String(decoding: generatedModuleMapData, as: UTF8.self)
        return generatedModuleMapContents
    }
}
