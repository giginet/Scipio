import Foundation
import ScipioKit
@preconcurrency import ArgumentParser
import Logging

extension Scipio {
    struct Prepare: AsyncParsableCommand {
        enum CachePolicy: String, CaseIterable, ExpressibleByArgument {
            case disabled
            case project
            case local
        }

        static let configuration: CommandConfiguration = .init(
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
            let logLevel: Logger.Level = globalOptions.verbose ? .trace : .info
            LoggingSystem.bootstrap(logLevel: logLevel)

            let runnerCacheMode: Runner.Options.CacheMode
            switch cachePolicy {
            case .disabled:
                runnerCacheMode = .disabled
            case .project:
                runnerCacheMode = .project
            case .local:
                runnerCacheMode = .storage(LocalCacheStorage(), [.consumer, .producer])
            }

            let runner = Runner(
                commandType: .prepare(cacheMode: runnerCacheMode),
                buildOptions: buildOptions,
                globalOptions: globalOptions
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
