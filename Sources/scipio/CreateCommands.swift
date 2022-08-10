import Foundation
import ScipioKit
import ArgumentParser

extension Scipio {
    struct Create: AsyncParsableCommand {
        @Argument(help: "Path indicates a package directory.",
                  completion: .directory)
        var packageDirectory: URL = URL(fileURLWithPath: ".")

        @Option(name: .customShort("o"),
                help: "Path indicates a XCFrameworks output directory.")
        var outputDirectory: URL?

        @Option(name: [.customLong("configuration"), .customShort("c")],
                help: "Build configuration for generated frameworks. (debug / release)")
        var buildConfiguration: BuildConfiguration = .release

        @Flag(name: .customLong("enable-cache"),
              help: "Whether skip building already built frameworks or not.")
        var isCacheEnabled = false

        @Flag(name: .customLong("embed-debug-symbols"),
              help: "Whether embed debug symbols to frameworks or not.")
        var isDebugSymbolEmbedded = false

        @Flag(name: [.short, .long],
              help: "Whether to overwrite existing frameworks.")
        var force: Bool = false

        @Flag(name: [.short, .long],
              help: "Provide additional build progress.")
        var verbose: Bool = false

        mutating func run() async throws {
            let runner = Runner(options: .init(
                buildOptions: .init(tag: nil,
                                    buildConfiguration: buildConfiguration,
                                    isSimulatorSupported: true,
                                    isDebugSymbolsEmbedded: isDebugSymbolEmbedded),
                packageDirectory: packageDirectory,
                outputDirectory: outputDirectory,
                isCacheEnabled: isCacheEnabled,
                force: force,
                verbose: verbose)
            )

            try await runner.run(packageDirectory: packageDirectory,
                                 frameworkOutputDir: outputDirectory)
        }
    }
}
