import Foundation
import ScipioKit
import ArgumentParser
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
        var platforms: [SDK] = []

        mutating func run() async throws {
            LoggingSystem.bootstrap()

            let platformsToCreate: Set<SDK>?
            if platforms.isEmpty {
                platformsToCreate = nil
            } else {
                platformsToCreate = Set(platforms)
            }

            let runner = Runner(mode: .createPackage(platforms: platformsToCreate),
                                options: .init(
                                    buildConfiguration: buildOptions.buildConfiguration,
                                    isSimulatorSupported: buildOptions.supportSimulators,
                                    isDebugSymbolsEmbedded: buildOptions.embedDebugSymbols,
                                    frameworkType: buildOptions.frameworkType,
                                    cacheMode: .disabled,
                                    force: buildOptions.force,
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

private let availablePlatforms: [SDK] = [.iOS, .macOS, .tvOS, .watchOS]

extension SDK: ExpressibleByArgument {
    public init?(argument: String) {
        if let initialized = SDK(rawValue: argument) {
            self = initialized
        } else {
            return nil
        }
    }
}
