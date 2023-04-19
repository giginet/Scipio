import Foundation
import ScipioKit
import ArgumentParser
import Logging

extension Scipio {
    struct DumpCacheKey: AsyncParsableCommand {
        static var configuration: CommandConfiguration = .init(
            abstract: "Dump cache key of a VersionFile"
        )

        @Argument(
            help: "Path indicates a version file to dump",
            completion: .file(extensions: ["version"]),
            transform: URL.init(fileURLWithPath:)
        )
        var versionFileURL: URL

        mutating func run() async throws {
            let decoder = VersionFileDecoder()
            let cacheKey = try decoder.decode(versionFile: versionFileURL)
            let checksum = try cacheKey.calculateChecksum()
            print(checksum)
        }
    }
}
