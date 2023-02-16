import Foundation
import XCTest
@testable import ScipioKit

final class BuildOptionsTests: XCTestCase {
    func testConcatenatingExtraFlags() {
        let base = ExtraFlags(
            cFlags: ["a"],
            cxxFlags: ["a"],
            swiftFlags: nil,
            linkerFlags: nil
        )

        let overriding = ExtraFlags(
            cFlags: ["b"],
            cxxFlags: nil,
            swiftFlags: ["b"],
            linkerFlags: nil
        )

        let overridden = base.concatenating(overriding)

        XCTAssertEqual(
            overridden.cFlags,
            ["a", "b"]
        )
        XCTAssertEqual(
            overridden.cxxFlags,
            ["a"]
        )
        XCTAssertEqual(
            overridden.swiftFlags,
            ["b"]
        )
        XCTAssertEqual(
            overridden.linkerFlags,
            []
        )
    }
}
