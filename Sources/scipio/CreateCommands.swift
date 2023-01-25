import Foundation
import ScipioKit
import ArgumentParser
import OrderedCollections
import Logging

extension Scipio {
    struct Create: AsyncParsableCommand {
        static var configuration: CommandConfiguration = .init(
            abstract: "Create XCFramework for a single package."
        )

        @Argument(help: "Path indicates a package directory.",
                  completion: .directory)
        var packageDirectory: URL = URL(fileURLWithPath: ".")

        @OptionGroup var buildOptions: BuildOptionGroup
        @OptionGroup var globalOptions: GlobalOptionGroup

        @Option(help: "Platforms to create XCFramework for.(availables: \(availablePlatforms.map(\.rawValue).joined(separator: ", ")))",
                completion: .list(availablePlatforms.map(\.rawValue)))
        var platforms: [Runner.Options.Platform] = []

        mutating func run() async throws {
            LoggingSystem.bootstrap()

            let platform: Runner.Options.PlatformSpecifier
            if platforms.isEmpty {
                platform = .manifest
            } else {
                platform = .specific(Set(platforms))
            }

            let runner = Runner(mode: .createPackage,
                                options: .init(
                                    baseBuildOptions: .init(
                                        buildConfiguration: buildOptions.buildConfiguration,
                                        platforms: platform,
                                        isSimulatorSupported: buildOptions.supportSimulators,
                                        isDebugSymbolsEmbedded: buildOptions.embedDebugSymbols,
                                        frameworkType: buildOptions.frameworkType
                                    ),
                                    cacheMode: .disabled,
                                    skipProjectGeneration: globalOptions.skipProjectGeneration,
                                    overwrite: buildOptions.overwrite,
                                    verbose: globalOptions.verbose
                                )
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

private let availablePlatforms: OrderedSet<SDK> = [.iOS, .macOS, .tvOS, .watchOS]

extension Runner.Options.Platform: ExpressibleByArgument { }
