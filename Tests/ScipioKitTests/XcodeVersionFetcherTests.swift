import Foundation
import Testing
@testable import ScipioKit

@Suite
struct XcodeVersionFetcherTests {
    @Test
    func fetchVersionForStableVersion() async throws {
        let result = """
Xcode 15.4
Build version 15F31d
"""

        let executor = makeExecutor(outputString: result)
        let fetcher = XcodeVersionFetcher(executor: executor)
        let xcodeVersion = try #require(try await fetcher.fetchXcodeVersion(), "xcodeVersion can be parsed")
        #expect(xcodeVersion.xcodeVersion == "15.4")
        #expect(xcodeVersion.xcodeBuildVersion == "15F31d")
    }

    @Test
    func fetchVersionForBetaVersion() async throws {
        let result = """
Xcode 16.0 Beta 2
Build version AAAAAA
"""

        let executor = makeExecutor(outputString: result)
        let fetcher = XcodeVersionFetcher(executor: executor)
        let xcodeVersion = try #require(try await fetcher.fetchXcodeVersion(), "xcodeVersion can be parsed")
        #expect(xcodeVersion.xcodeVersion == "16.0 Beta 2")
        #expect(xcodeVersion.xcodeBuildVersion == "AAAAAA")
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
