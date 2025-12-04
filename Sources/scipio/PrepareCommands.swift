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
                      Specify how to reuse cache for both frameworks and resolved packages.
                      Can be overridden by --framework-cache-policy or --resolved-packages-cache-policy.
                      (\(CachePolicy.allCases.map(\.rawValue).joined(separator: " / ")))
                      """,
                completion: .list(CachePolicy.allCases.map(\.rawValue)))
        var cachePolicy: CachePolicy = .project

        @Option(name: [.customLong("framework-cache-policy")],
                help: "Specify how to reuse framework cache. (\(CachePolicy.allCases.map(\.rawValue).joined(separator: " / ")))",
                completion: .list(CachePolicy.allCases.map(\.rawValue)))
        var frameworkCachePolicy: CachePolicy?

        @Option(name: [.customLong("resolved-packages-cache-policy")],
                help: "Specify how to reuse resolved packages cache. (\(CachePolicy.allCases.map(\.rawValue).joined(separator: " / ")))",
                completion: .list(CachePolicy.allCases.map(\.rawValue)))
        var resolvedPackagesCachePolicy: CachePolicy?

        @OptionGroup var buildOptions: BuildOptionGroup
        @OptionGroup var globalOptions: GlobalOptionGroup

        mutating func run() async throws {
            let logLevel: Logger.Level = globalOptions.verbose ? .trace : .info
            LoggingSystem.bootstrap(logLevel: logLevel)

            let frameworkCachePolicies: [Runner.Options.FrameworkCachePolicy]
            switch frameworkCachePolicy ?? cachePolicy {
            case .disabled:
                frameworkCachePolicies = .disabled
            case .project:
                frameworkCachePolicies = [.project]
            case .local:
                frameworkCachePolicies = [.localDisk]
            }

            let resolvedPackagesCachePolicies: [Runner.Options.ResolvedPackagesCachePolicy]
            switch resolvedPackagesCachePolicy ?? cachePolicy {
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
