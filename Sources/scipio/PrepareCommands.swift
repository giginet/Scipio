import Foundation
import ScipioKit
import ArgumentParser
import Logging

extension Scipio {
    struct Prepare: AsyncParsableCommand {
        enum CachePolicy: String, CaseIterable, ExpressibleByArgument {
            case disabled
            case project
            case local
        }

        static var configuration: CommandConfiguration = .init(
            abstract: "Prepare all dependencies in a specific manifest."
        )

        @Argument(help: "Path indicates a package directory.",
                  completion: .directory)
        var packageDirectory: URL = URL(fileURLWithPath: ".")

        @Option(name: [.customLong("cache-policy")],
                help: "Specify how to reuse cache. (\(CachePolicy.allCases.map(\.rawValue).joined(separator: " / ")))",
                completion: .list(CachePolicy.allCases.map(\.rawValue)))
        var cachePolicy: CachePolicy = .project

        @OptionGroup var buildOptions: BuildOptionGroup
        @OptionGroup var globalOptions: GlobalOptionGroup

        mutating func run() async throws {
            LoggingSystem.bootstrap()

            let runnerCacheMode: Runner.Options.CacheMode
            switch cachePolicy {
            case .disabled:
                runnerCacheMode = .disabled
            case .project:
                runnerCacheMode = .project
            case .local:
                runnerCacheMode = .storage(LocalCacheStorage())
            }

            let runner = Runner(
                mode: .prepareDependencies,
                options: .init(
                    buildConfiguration: buildOptions.buildConfiguration,
                    isSimulatorSupported: buildOptions.supportSimulators,
                    isDebugSymbolsEmbedded: buildOptions.embedDebugSymbols,
                    frameworkType: buildOptions.frameworkType,
                    cacheMode: runnerCacheMode,
                    overwrite: buildOptions.overwrite,
                    verbose: globalOptions.verbose)
            )

            let outputDir: Runner.OutputDirectory
            if let customOutputDir = buildOptions.customOutputDirectory {
                outputDir = .custom(customOutputDir)
            } else {
                outputDir = .default
            }

            try await runner.run(packageDirectory: packageDirectory,
                                 frameworkOutputDir: outputDir)
        }
    }
}
