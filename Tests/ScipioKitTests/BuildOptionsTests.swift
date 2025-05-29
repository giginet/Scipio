import Foundation
import Testing
@testable import ScipioKit

@Suite
struct BuildOptionsTests {
    @Test
    func concatenatingExtraFlags() {
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

        #expect(
            overridden.cFlags == ["a", "b"]
        )
        #expect(
            overridden.cxxFlags == ["a"]
        )
        #expect(
            overridden.swiftFlags == ["b"]
        )
        #expect(
            overridden.linkerFlags == []
        )
    }
}
