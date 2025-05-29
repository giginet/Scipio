@testable import ScipioKit
import Testing

@Suite
struct ClangCheckerTests {
    private let clangVersion = """
    Apple clang version 14.0.0 (clang-1400.0.29.102)
    Target: arm64-apple-darwin21.6.0
    Thread model: posix
    InstalledDir: /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin
    """

    @Test
    func parseClangVersion() async throws {
        let hook = { arguments in
            #expect(arguments == ["/usr/bin/xcrun", "clang", "--version"])
            return StubbableExecutorResult(arguments: arguments, success: self.clangVersion)
        }
        let clangParser = ClangChecker(executor: StubbableExecutor(executeHook: hook))
        let version = try await clangParser.fetchClangVersion()
        #expect(version == "clang-1400.0.29.102")
    }
}
