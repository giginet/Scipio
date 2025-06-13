import Foundation
import Testing
import TSCBasic
import PackageManifestKit
@testable import ScipioKit

struct VariousModulePathsTests {
    private static let fixturePath = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .appending(components: "Resources", "Fixtures", "VariousModulePathsTests")

    private static let packages: [URL] = [
        fixturePath.appending(components: "WithExplicitPath"),
        fixturePath.appending(components: "WithoutPath_LowercaseDir_srcs"),
        fixturePath.appending(components: "WithoutPath_LowercaseDir_source"),
        fixturePath.appending(components: "WithoutPath_SingleModule"),
        fixturePath.appending(components: "WithoutPath_LowercaseDir_sources"),
        fixturePath.appending(components: "WithoutPath_UppercaseMix"),
        fixturePath.appending(components: "WithoutPath_LowercaseDir_src"),
    ]

    let fileSystem = TSCBasic.localFileSystem
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
