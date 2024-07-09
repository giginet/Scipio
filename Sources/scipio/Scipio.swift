import Foundation
@preconcurrency import ArgumentParser

@main
struct Scipio: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "A build tool to create XCFrameworks from Swift packages.",
        subcommands: [Create.self, Prepare.self, DumpCacheKey.self],
        defaultSubcommand: Prepare.self)
}
