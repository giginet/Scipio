import Foundation
@testable import ScipioKit
import XCTest

final class ClangCheckerTests: XCTestCase {
    private let clangVersion = """
Apple clang version 14.0.0 (clang-1400.0.29.102)
Target: arm64-apple-darwin21.6.0
Thread model: posix
InstalledDir: /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin
"""

    func testParseClangVersion() async throws {
        let hook = { arguments in
            XCTAssertEqual(arguments, ["/usr/bin/xcrun", "clang", "--version"])
            return StubbableExecutorResult(arguments: arguments, success: self.clangVersion)
        }
        let clangParser = ClangChecker(executor: StubbableExecutor(executeHook: hook))
        let version = try await clangParser.fetchClangVersion()
        XCTAssertEqual(version, "clang-1400.0.29.102")
    }

    func testEncodeCacheKey() throws {
        let cacheKey = CacheKey(targetName: "MyTarget",
                                pin: .revision("111111111"),
                                buildOptions: .init(buildConfiguration: .release,
                                                    isDebugSymbolsEmbedded: false,
                                                    frameworkType: .dynamic,
                                                    sdks: [.iOS]),
                                clangVersion: "clang-1400.0.29.102")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(cacheKey)
        let rawString = try XCTUnwrap(String(data: data, encoding: .utf8))
        let expected = """
{
  "buildOptions" : {
    "buildConfiguration" : "release",
    "isDebugSymbolsEmbedded" : false,
    "frameworkType" : "dynamic",
    "sdks" : [
      "iOS"
    ]
  },
  "targetName" : "MyTarget",
  "clangVersion" : "clang-1400.0.29.102",
  "pin" : {
    "revision" : "111111111"
  }
}
"""
        XCTAssertEqual(rawString, expected)
    }
}
