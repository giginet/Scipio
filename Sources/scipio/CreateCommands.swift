import Foundation
import ScipioKit
import ArgumentParser
import TSCBasic

extension Scipio {
    struct Create: AsyncParsableCommand {
        mutating func run() async throws {
            let runner = Runner()

            let packageDirectory = URL(fileURLWithPath: "/Users/jp30698/work/xcframeworks/test-package")

            try await runner.run(packageDirectory: packageDirectory,
                                 frameworkOutputDir: packageDirectory.appendingPathComponent("XCFrameworks"))
        }
    }
}
