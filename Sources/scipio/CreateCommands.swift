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
        var platforms: [Runner.Options.Platform] = []

        mutating func run() async throws {
            let logLevel: Logger.Level = globalOptions.verbose ? .info : .warning
            LoggingSystem.bootstrap(logLevel: logLevel)

            let platformSpecifier: Runner.Options.PlatformSpecifier
            if platforms.isEmpty {
                platformSpecifier = .manifest
            } else {
                platformSpecifier = .specific(Set(platforms))
            }

            let runner = Runner(
                commandType: .create(platformSpecifier: platformSpecifier),
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

private let availablePlatforms: Set<SDK> = [.iOS, .macOS, .tvOS, .watchOS]

extension Runner.Options.Platform: ExpressibleByArgument { }
