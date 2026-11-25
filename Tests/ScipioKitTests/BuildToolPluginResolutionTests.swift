import Foundation
import Testing
@testable import ScipioKit

struct BuildToolPluginResolutionTests {
    @Test("Local build tool plugins are resolved without becoming runtime framework dependencies", .temporaryDirectory)
    func localPluginDependencies() async throws {
        let root = TemporaryDirectory.url
        let fileSystem = LocalFileSystem.default
        try fileSystem.writeFileContents(root.appending(component: "Package.swift"), data: Data("""
        // swift-tools-version: 6.0
        import PackageDescription
        import CompilerPluginSupport
        let package = Package(name: "Fixture", products: [.library(name: "Library", targets: ["Library"])], targets: [
            .macro(name: "Macro", plugins: [.plugin(name: "GenerateSources")]),
            .target(name: "Library", dependencies: ["Macro"]),
            .plugin(name: "GenerateSources", capability: .buildTool(), dependencies: ["Generator"]),
            .executableTarget(name: "Generator", dependencies: ["HostSupport"]),
            .target(name: "HostSupport")
        ])
        """.utf8))
        for name in ["Macro", "Library", "Generator", "HostSupport"] {
            let source = root.appending(components: "Sources", name, "Source.swift")
            try fileSystem.writeFileContents(source, data: Data("struct Fixture {}".utf8))
        }
        let pluginSource = root.appending(components: "Plugins", "GenerateSources", "Plugin.swift")
        try fileSystem.writeFileContents(pluginSource, data: Data("import PackagePlugin".utf8))

        let package = try await DescriptionPackage(
            packageDirectory: root, mode: .createPackage, resolvedPackagesCachePolicies: [], onlyUseVersionsFromResolvedFile: false
        )
        let macro = try #require(package.graph.module(for: "Macro"))
        #expect(macro.dependencies.isEmpty)
        let plugin = try #require(macro.pluginDependencies.first?.module)
        #expect(plugin.name == "GenerateSources")
        let generator = try #require(plugin.dependencies.first?.module)
        #expect(generator.underlying.type == .executable)
        #expect(generator.dependencies.first?.module?.name == "HostSupport")
        #expect(try package.resolveBuildProductDependencyGraph().allNodes.map(\.value.target.name) == ["Library"])
    }
}
