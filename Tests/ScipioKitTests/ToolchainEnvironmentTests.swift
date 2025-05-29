import Testing
@testable import ScipioKit
@_spi(SwiftPMInternal) import struct Basics.Environment

@Suite
struct ToolchainEnvironmentTests {

    @Test
    func basics() {
        let environment = [
            "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
        ]

        #expect(environment.developerDirPath == "/Applications/Xcode.app/Contents/Developer")
        #expect(
            environment.toolchainBinPath?.pathString == "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
        )
    }

}
