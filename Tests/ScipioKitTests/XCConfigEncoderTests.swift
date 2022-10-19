import Foundation
@testable import ScipioKit
import XCTest

final class XCConfigEncoderTests: XCTestCase {
    func testEncode() {
        let encoder = XCConfigEncoder()
        let configs: [String: any XCConfigValue] = [
            "MACH_O_TYPE": "staticlib",
            "ENABLE_BITCODE": true,
        ]
        let data = encoder.generate(configs: configs)
        XCTAssertEqual(
            String(data: data, encoding: .utf8),
            """
            ENABLE_BITCODE = YES
            MACH_O_TYPE = staticlib
            """
        )
    }
}
