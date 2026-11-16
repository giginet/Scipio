import CacheStorage
import Foundation
import Testing
@testable import ScipioKit

@Suite(.enabled(if: ProcessInfo.processInfo.environment["ENABLE_INTEGRATION_TESTS"] == "1"))
struct MacroIntegrationTests {
    @Test("Generated public macros survive cache restoration and invalidate when only their generator changes", .temporaryDirectory)
    func generatedMacroInvalidation() async throws {
        let fixture = GeneratedMacroFixture(root: TemporaryDirectory.url)
        try await fixture.create()
        let runner = Runner(mode: .prepareDependencies, options: .init(
            baseBuildOptions: .init(buildConfiguration: .debug, platforms: .specific([.iOS, .macOS]), frameworkType: .static),
            frameworkCachePolicies: [.localDisk(baseURL: fixture.cache)],
            resolvedPackagesCachePolicies: [.localDisk(baseURL: fixture.root.appending(component: "resolved-cache"))]
        ))
        try await runner.run(packageDirectory: fixture.parent, frameworkOutputDir: .custom(fixture.output))
        #expect(try await fixture.expandedValue() == "41")
        let firstVersion = try fixture.version(for: "Client")
        let firstDeclarations = try fixture.version(for: "Declarations")
        let macroVersion = fixture.parent.appending(components: ".build", "scipio", "MacroPlugins", ".FixturePlugin.version")
        let firstMacro = try Data(contentsOf: macroVersion)
        let key = try JSONDecoder().decode(MacroCacheKey.self, from: firstMacro)
        #expect(Set(key.dependencies.map(\.targetName)).isSuperset(of: ["GenerateImplementation", "GeneratorTool", "HostToolsSupport"]))
        #expect(!LocalFileSystem.default.exists(fixture.output.appending(component: "HostSupport.xcframework")))
        #expect(!LocalFileSystem.default.exists(fixture.output.appending(component: "HostToolsSupport.xcframework")))
        let metadata = fixture.parent.appending(components: ".build", "scipio", "MacroPlugins", "plugins.json")
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: [[String: Any]]])
        #expect(manifest["plugins"]?.first?["targets"] as? [String] == ["Client", "Declarations"])

        try fixture.removeOutputs()
        try await runner.run(packageDirectory: fixture.parent, frameworkOutputDir: .custom(fixture.output))
        #expect(try await fixture.expandedValue() == "41")
        #expect(try fixture.version(for: "Client") == firstVersion)
        #expect(try Data(contentsOf: macroVersion) == firstMacro)

        try await fixture.updateGenerator()
        try await runner.run(packageDirectory: fixture.parent, frameworkOutputDir: .custom(fixture.output))
        #expect(try await fixture.expandedValue() == "42")
        #expect(try fixture.version(for: "Client") != firstVersion)
        #expect(try fixture.version(for: "Declarations") != firstDeclarations)
        #expect(try Data(contentsOf: macroVersion) != firstMacro)

        let updatedVersion = try fixture.version(for: "Client")
        try fixture.removeOutputs()
        try await runner.run(packageDirectory: fixture.parent, frameworkOutputDir: .custom(fixture.output))
        #expect(try await fixture.expandedValue() == "42")
        #expect(try fixture.version(for: "Client") == updatedVersion)
    }

}
