import Foundation
import ArgumentParser

@main
struct Scipio: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "A build tool to create XCFrameworks from Swift packages.",
        subcommands: [Create.self, Prepare.self, DumpCacheKey.self],
        defaultSubcommand: Prepare.self)
}
