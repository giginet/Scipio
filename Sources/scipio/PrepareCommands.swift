import Foundation
import ScipioKit
import ArgumentParser
import Logging

extension Scipio {
    struct Prepare: AsyncParsableCommand {
        static var configuration: CommandConfiguration = .init(
            abstract: "Prepare all dependencies in a specific manifest."
        )

        @Argument(help: "Path indicates a package directory.",
                  completion: .directory)
        var packageDirectory: URL = URL(fileURLWithPath: ".")


        @Flag(name: .customLong("enable-cache"),
              help: "Whether skip building already built frameworks or not.")
        var cacheEnabled = false

        @OptionGroup var buildOptions: BuildOptionGroup
        @OptionGroup var globalOptions: GlobalOptionGroup
        
        mutating func run() async throws {
            LoggingSystem.bootstrap(StreamLogHandler.standardError)
            
            let runner = Runner(options: .init(
                buildConfiguration: buildOptions.buildConfiguration,
                isSimulatorSupported: buildOptions.supportSimulator,
                isDebugSymbolsEmbedded: buildOptions.embedDebugSymbols,
                isCacheEnabled: cacheEnabled,
                verbose: globalOptions.verbose)
            )
            
            try await runner.prepareDependencies(packageDirectory: packageDirectory,
                                                 frameworkOutputDir: buildOptions.outputDirectory)
        }
    }
}
