import Foundation
import ScipioKit
import ArgumentParser

extension Scipio {
    struct Create: AsyncParsableCommand {
        @Argument(help: "Path indicates a package directory.")
        var packageDirectory: URL = .init(fileURLWithPath: ".")

        @Option(help: "Path indicates a XCFrameworks output directory.")
        var output: URL?

        @Option(help: "Build Configuration for generated frameworks. (debug / release)")
        var configuration: BuildConfiguration = .release

        mutating func run() async throws {
            let runner = Runner()

            try await runner.run(packageDirectory: packageDirectory,
                                 frameworkOutputDir: output)
        }
    }
}
