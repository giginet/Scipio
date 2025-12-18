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
                help: """
                      [DEPRECATED] Use --framework-cache-policy instead.
                      Specify how to reuse framework cache. (\(CachePolicy.allCases.map(\.rawValue).joined(separator: " / ")))
                      """,
                completion: .list(CachePolicy.allCases.map(\.rawValue)))
        var cachePolicy: CachePolicy?

        @Option(name: [.customLong("framework-cache-policy")],
                help: "Specify how to reuse framework cache. (\(CachePolicy.allCases.map(\.rawValue).joined(separator: " / ")))",
                completion: .list(CachePolicy.allCases.map(\.rawValue)))
        var frameworkCachePolicy: CachePolicy = .project

        @Option(name: [.customLong("resolved-packages-cache-policy")],
                help: "Specify how to reuse resolved packages cache. (\(CachePolicy.allCases.map(\.rawValue).joined(separator: " / ")))",
                completion: .list(CachePolicy.allCases.map(\.rawValue)))
        var resolvedPackagesCachePolicy: CachePolicy = .disabled

        @OptionGroup var buildOptions: BuildOptionGroup
        @OptionGroup var globalOptions: GlobalOptionGroup

        mutating func run() async throws {
            let logLevel: Logger.Level = globalOptions.verbose ? .trace : .info
            LoggingSystem.bootstrap(logLevel: logLevel)

            // Show deprecation warning if cachePolicy is used
            if cachePolicy != nil {
                logger.warning("--cache-policy is deprecated. Please use --framework-cache-policy instead.")
            }

            let frameworkCachePolicies: [Runner.Options.FrameworkCachePolicy]
            switch cachePolicy ?? frameworkCachePolicy {
            case .disabled:
                frameworkCachePolicies = .disabled
            case .project:
                frameworkCachePolicies = [.project]
            case .local:
                frameworkCachePolicies = [.localDisk]
            }

            let resolvedPackagesCachePolicies: [Runner.Options.ResolvedPackagesCachePolicy]
            switch resolvedPackagesCachePolicy {
            case .disabled:
                resolvedPackagesCachePolicies = .disabled
            case .project:
                resolvedPackagesCachePolicies = [.project]
            case .local:
                resolvedPackagesCachePolicies = [.localDisk]
            }

            let runner = Runner(
                commandType: .prepare(
                    frameworkCachePolicies: frameworkCachePolicies,
                    resolvedPackagesCachePolicies: resolvedPackagesCachePolicies
                ),
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
