import Foundation
@testable import ScipioKit
import XCTest

final class XCConfigEncoderTests: XCTestCase {
    func testEncode() {
        let encoder = XCConfigEncoder()
        let configs: [String: XCConfigValue] = [
            "MACH_O_TYPE": "staticlib",
            "BUILD_LIBRARY_FOR_DISTRIBUTION": true,
        ]
        let data = encoder.generate(configs: configs)
        XCTAssertEqual(
            String(data: data, encoding: .utf8),
            """
            BUILD_LIBRARY_FOR_DISTRIBUTION = YES
            MACH_O_TYPE = staticlib
            """
        )
    }
}
