import Foundation
import RegexBuilder

public struct XcodeVersion: Sendable, Hashable {
    var xcodeVersion: String
    var xcodeBuildVersion: String
}

struct XcodeVersionFetcher<E: Executor> {
    private let executor: E

    init(executor: E) {
        self.executor = executor
    }

    func fetchXcodeVersion() async throws -> XcodeVersion? {
        let result = try await executor.execute("/usr/bin/xcrun", "xcodebuild", "-version")
        let rawString = try result.unwrapOutput()
        return parseXcodeVersion(from: rawString)
    }

    private func parseXcodeVersion(from output: String) -> XcodeVersion? {
        let xcodeVersionRef = Reference(Substring.self)
        let xcodeBuildVersionRef = Reference(Substring.self)
        // Parse the output like:
        //  Xcode 15.4
        //  Build version 15F31d
        let regex = Regex {
            "Xcode"
            One(.whitespace)
            Capture(as: xcodeVersionRef) {
                OneOrMore(.anyNonNewline)
            }
            One(.newlineSequence)
            "Build version"
            One(.whitespace)
            Capture(as: xcodeBuildVersionRef) {
                OneOrMore(.hexDigit)
            }
        }
        guard let matches = output.matches(of: regex).first else {
            return nil
        }
        let xcodeVersion = String(matches[xcodeVersionRef])
        let xcodeBuildVersion = String(matches[xcodeBuildVersionRef])
        return XcodeVersion(
            xcodeVersion: xcodeVersion,
            xcodeBuildVersion: xcodeBuildVersion
        )
    }
}
