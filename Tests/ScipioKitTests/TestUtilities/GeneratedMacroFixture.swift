import Foundation
@testable @_spi(Internals) import ScipioKit

struct GeneratedMacroFixture {
    let root: URL
    let generator: URL
    let macros: URL
    let client: URL
    let parent: URL
    let output: URL
    let cache: URL
    private let fileSystem = LocalFileSystem.default
    private let executor = ProcessExecutor()

    init(root: URL) {
        self.root = root
        generator = root.appending(component: "Generator")
        macros = root.appending(component: "MacroLibrary")
        client = root.appending(component: "ClientPackage")
        parent = root.appending(component: "Parent")
        output = root.appending(component: "XCFrameworks")
        cache = root.appending(component: "cache")
    }

    func create() async throws {
        try write(Self.generatorManifest, to: generator.appending(component: "Package.swift"))
        try write(Self.pluginSource, to: generator.appending(components: "Plugins", "GenerateImplementation", "Plugin.swift"))
        try write(Self.generatorSource, to: generator.appending(components: "Sources", "GeneratorTool", "main.swift"))
        try write("import AppKit\npublic let generatedValue = 41", to: generator.appending(components: "Sources", "HostToolsSupport", "Value.swift"))
        try await initializeRepository(generator)
        try await git(["-C", generator.path, "tag", "1.0.0"])

        try write("""
        // swift-tools-version: 6.0
        import PackageDescription
        import CompilerPluginSupport
        let package = Package(name: "MacroLibrary", platforms: [.macOS(.v14), .iOS(.v15)],
            products: [.library(name: "PublicDeclarations", targets: ["Declarations", "Runtime"])],
            dependencies: [
                .package(url: \(quoted(generator.absoluteString)), from: "1.0.0"),
                .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "602.0.0")
            ],
            targets: [
                .target(name: "HostSupport"),
                .target(name: "SharedSupport"),
                .target(name: "Runtime", dependencies: ["SharedSupport"]),
                .macro(name: "FixturePlugin", dependencies: [
                    "HostSupport", "SharedSupport",
                    .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                    .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                    .product(name: "SwiftSyntaxBuilder", package: "swift-syntax")
                ], plugins: [.plugin(name: "ImplementationGenerator", package: "Generator")]),
                .target(name: "Declarations", dependencies: ["FixturePlugin"])
            ])
        """, to: macros.appending(component: "Package.swift"))
        try write("import AppKit\npublic let hostValue = 0",
                  to: macros.appending(components: "Sources", "HostSupport", "Host.swift"))
        try write("public let sharedValue = 0", to: macros.appending(components: "Sources", "SharedSupport", "Shared.swift"))
        try write("import SharedSupport\npublic let runtimeValue = sharedValue",
                  to: macros.appending(components: "Sources", "Runtime", "Runtime.swift"))
        try write(Self.macroSource, to: macros.appending(components: "Sources", "FixturePlugin", "Plugin.swift"))
        try write("""
        @freestanding(expression)
        public macro answer() -> Int = #externalMacro(module: "FixturePlugin", type: "AnswerMacro")
        """, to: macros.appending(components: "Sources", "Declarations", "Declarations.swift"))
        try await initializeRepository(macros)

        try write("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "ClientPackage", platforms: [.macOS(.v14), .iOS(.v15)],
            products: [.library(name: "Client", targets: ["Client"])],
            dependencies: [.package(url: \(quoted(macros.absoluteString)), branch: "main")],
            targets: [.target(name: "Client", dependencies: [.product(name: "PublicDeclarations", package: "MacroLibrary")])])
        """, to: client.appending(component: "Package.swift"))
        try write("import Declarations\nimport Runtime\npublic func answerValue() -> Int { #answer() + runtimeValue }",
                  to: client.appending(components: "Sources", "Client", "Client.swift"))
        try await initializeRepository(client)
        try write("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Parent", platforms: [.macOS(.v14), .iOS(.v15)],
            dependencies: [.package(url: \(quoted(client.absoluteString)), branch: "main")],
            targets: [.target(name: "Parent", dependencies: [.product(name: "Client", package: "ClientPackage")])])
        """, to: parent.appending(component: "Package.swift"))
        try write("struct Parent {}", to: parent.appending(components: "Sources", "Parent", "Parent.swift"))
    }

    func updateGenerator() async throws {
        try write("import AppKit\npublic let generatedValue = 42", to: generator.appending(components: "Sources", "HostToolsSupport", "Value.swift"))
        try await git(["-C", generator.path, "add", "."])
        try await git(["-C", generator.path, "commit", "-qm", "Update generated value"])
        try await git(["-C", generator.path, "tag", "1.0.1"])
        _ = try await executor.execute(
            "/usr/bin/xcrun", "swift", "package", "--package-path", parent.path, "update", "generator"
        ).unwrapOutput()
    }

    func expandedValue() async throws -> String {
        let source = root.appending(component: "main.swift")
        let executable = root.appending(component: "ExpandedValue")
        try write("import Client\nprint(answerValue())", to: source)
        var flags: [String] = []
        for name in ["Client", "Declarations", "Runtime", "SharedSupport"] {
            let framework = output.appending(component: "\(name).xcframework")
            let slice = try fileSystem.getDirectoryContents(framework).first { $0.hasPrefix("macos-") }
            guard let slice else { throw CocoaError(.fileNoSuchFile) }
            flags += ["-F", framework.appending(component: slice).path, "-framework", name]
        }
        _ = try await executor.execute(["/usr/bin/xcrun", "swiftc", source.path, "-o", executable.path] + flags).unwrapOutput()
        return try await executor.execute([executable.path]).unwrapOutput().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func version(for name: String) throws -> Data {
        try fileSystem.readFileContents(output.appending(component: ".\(name).version"))
    }

    func removeOutputs() throws {
        try fileSystem.removeFileTree(output)
        let plugins = parent.appending(components: ".build", "scipio", "MacroPlugins")
        if fileSystem.exists(plugins) { try fileSystem.removeFileTree(plugins) }
    }

    private func initializeRepository(_ directory: URL) async throws {
        try await git(["init", "-q", "-b", "main", directory.path])
        try await git(["-C", directory.path, "config", "user.email", "test@example.invalid"])
        try await git(["-C", directory.path, "config", "user.name", "Test"])
        try await git(["-C", directory.path, "add", "."])
        try await git(["-C", directory.path, "commit", "-qm", "Fixture"])
    }

    private func git(_ arguments: [String]) async throws {
        _ = try await executor.execute(["/usr/bin/git"] + arguments).unwrapOutput()
    }

    private func write(_ contents: String, to url: URL) throws {
        try fileSystem.writeFileContents(url, data: Data(contents.utf8))
    }

    private func quoted(_ string: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(string), as: UTF8.self)
    }
}

extension GeneratedMacroFixture {
    private static let generatorManifest = """
    // swift-tools-version: 6.0
    import PackageDescription
    let package = Package(name: "Generator", platforms: [.macOS(.v14)],
        products: [.plugin(name: "ImplementationGenerator", targets: ["GenerateImplementation"])],
        targets: [
            .plugin(name: "GenerateImplementation", capability: .buildTool(), dependencies: ["GeneratorTool"]),
            .executableTarget(name: "GeneratorTool", dependencies: ["HostToolsSupport"]),
            .target(name: "HostToolsSupport")
        ])
    """

    private static let pluginSource = """
    import PackagePlugin
    @main struct GenerateImplementation: BuildToolPlugin {
        func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
            let output = context.pluginWorkDirectoryURL.appending(path: "Generated.swift")
            return [.buildCommand(displayName: "Generate macro implementation",
                executable: try context.tool(named: "GeneratorTool").url,
                arguments: [output.path], outputFiles: [output])]
        }
    }
    """

    private static let generatorSource = #"""
    import Foundation
    import HostToolsSupport
    try "let generatedMacroValue = \(generatedValue)".write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
    """#

    private static let macroSource = #"""
    import HostSupport
    import SharedSupport
    import SwiftSyntax
    import SwiftSyntaxBuilder
    import SwiftSyntaxMacros
    import SwiftCompilerPlugin
    public struct AnswerMacro: ExpressionMacro {
        public static func expansion(of node: some FreestandingMacroExpansionSyntax, in context: some MacroExpansionContext) throws -> ExprSyntax {
            "\(raw: generatedMacroValue + hostValue + sharedValue)"
        }
    }
    @main struct Plugin: CompilerPlugin {
        let providingMacros: [Macro.Type] = [AnswerMacro.self]
    }
    """#
}
