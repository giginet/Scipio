import Foundation
import ScipioKit
import ArgumentParser

extension Scipio {
    struct Create: AsyncParsableCommand {
        @Argument(help: "Path indicates a package directory.",
                  completion: .directory)
        var packageDirectory: URL = URL(fileURLWithPath: ".")

        @Option(name: [.customShort("o"), .customLong("output")],
                help: "Path indicates a XCFrameworks output directory.")
        var outputDirectory: URL?

        @Option(name: [.customLong("configuration"), .customShort("c")],
                help: "Build configuration for generated frameworks. (debug / release)")
        var buildConfiguration: BuildConfiguration = .release

        @Flag(name: .customLong("enable-cache"),
              help: "Whether skip building already built frameworks or not.")
        var cacheEnabled = false

        @Flag(name: .customLong("embed-debug-symbols"),
              help: "Whether embed debug symbols to frameworks or not.")
        var embedDebugSymbols = false

        @Flag(name: .customLong("support-simulator"),
              help: "Whether also building for simulators of each SDKs or not.")
        var supportSimulator = false

        @Flag(name: [.short, .long],
              help: "Provide additional build progress.")
        var verbose: Bool = false

        mutating func run() async throws {
            let runner = Runner(options: .init(
                buildConfiguration: buildConfiguration,
                isSimulatorSupported: supportSimulator,
                isDebugSymbolsEmbedded: embedDebugSymbols,
                packageDirectory: packageDirectory,
                isCacheEnabled: cacheEnabled,
                verbose: verbose)
            )

            try await runner.run(packageDirectory: packageDirectory,
                                 frameworkOutputDir: outputDirectory)
        }
    }
}
