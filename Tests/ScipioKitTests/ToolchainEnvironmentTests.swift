import XCTest
@testable import ScipioKit
@_spi(SwiftPMInternal) import struct Basics.Environment

final class ToolchainEnvironmentTests: XCTestCase {

    func testBasics() {
        let environment = [
            "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
        ]

        XCTAssertEqual(environment.developerDirPath, "/Applications/Xcode.app/Contents/Developer")
        XCTAssertEqual(
            environment.toolchainBinPath?.pathString,
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
        )
    }

}
