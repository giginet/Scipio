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
        let hook = { @Sendable [clangVersion] arguments in
            XCTAssertEqual(arguments, ["/usr/bin/xcrun", "clang", "--version"])
            return StubbableExecutorResult(arguments: arguments, success: clangVersion)
        }
        let clangParser = ClangChecker(executor: StubbableExecutor(executeHook: hook))
        let version = try await clangParser.fetchClangVersion()
        XCTAssertEqual(version, "clang-1400.0.29.102")
    }
}
