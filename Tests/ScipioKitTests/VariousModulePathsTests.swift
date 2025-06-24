import Foundation
import Testing
import PackageManifestKit
@testable import ScipioKit

struct VariousModulePathsTests {
    private static let fixturePath = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .appending(components: "Resources", "Fixtures", "VariousModulePathsTests")

    private static let packages: [URL] = [
        "WithExplicitPath",
        "WithoutPath_LowercaseDir_srcs",
        "WithoutPath_LowercaseDir_source",
        "WithoutPath_SingleModule",
        "WithoutPath_LowercaseDir_sources",
        "WithoutPath_UppercaseMix",
        "WithoutPath_LowercaseDir_src",
    ].map { fixturePath.appending(components: $0) }

    let fileSystem = LocalFileSystem.default
    let manifestLoader = ManifestLoader(executor: ProcessExecutor())

    @Test(
        "PackageResolver resolves modules for packages with explicit paths or default (case-insensitive) directory layouts",
        arguments: packages
    )
    func resolve(for packageURL: URL) async throws {
        let rootManifest = try await manifestLoader.loadManifest(for: packageURL)

        let resolver = try await PackageResolver(
            packageDirectory: packageURL,
            rootManifest: rootManifest,
            fileSystem: fileSystem
        )
        let modulesGraph = try await resolver.resolve()

        modulesGraph.allModules.forEach { module in
            #expect(module.name == packageURL.lastPathComponent)
        }
    }
}
