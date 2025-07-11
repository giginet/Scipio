import Foundation
import XCTest
@testable @_spi(Internals) import ScipioKit

final class XcodeVersionFetcherTests: XCTestCase {
    func testFetchVersionForStableVersion() async throws {
        let result = """
Xcode 15.4
Build version 15F31d
"""

        let executor = makeExecutor(outputString: result)
        let fetcher = XcodeVersionFetcher(executor: executor)
        guard let xcodeVersion = try await fetcher.fetchXcodeVersion() else {
            return XCTFail("xcodeVersion can be parsed")
        }
        XCTAssertEqual(xcodeVersion.xcodeVersion, "15.4")
        XCTAssertEqual(xcodeVersion.xcodeBuildVersion, "15F31d")
    }

    func testFetchVersionForBetaVersion() async throws {
        let result = """
Xcode 16.0 Beta 2
Build version AAAAAA
"""

        let executor = makeExecutor(outputString: result)
        let fetcher = XcodeVersionFetcher(executor: executor)
        guard let xcodeVersion = try await fetcher.fetchXcodeVersion() else {
            return XCTFail("xcodeVersion can be parsed")
        }
        XCTAssertEqual(xcodeVersion.xcodeVersion, "16.0 Beta 2")
        XCTAssertEqual(xcodeVersion.xcodeBuildVersion, "AAAAAA")
    }

    private func makeExecutor(outputString: String) -> some Executor {
        StubbableExecutor(executeHook: { _ in
            StubbableExecutorResult(
                arguments: [],
                success: outputString
            )
        })
    }
}
