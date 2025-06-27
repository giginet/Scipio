import Foundation
import Testing
@testable import PIFKit

@Suite
struct PlatformTests {
    @Test
    func platformRawValues() {
        #expect(Platform.iOS.rawValue == "ios")
        #expect(Platform.iOSSimulator.rawValue == "ios-simulator")
        #expect(Platform.macOS.rawValue == "macos")
        #expect(Platform.tvOS.rawValue == "tvos")
        #expect(Platform.tvOSSimulator.rawValue == "tvos-simulator")
        #expect(Platform.watchOS.rawValue == "watchos")
        #expect(Platform.watchOSSimulator.rawValue == "watchos-simulator")
        #expect(Platform.visionOS.rawValue == "visionos")
        #expect(Platform.visionOSSimulator.rawValue == "visionos-simulator")
        #expect(Platform.macCatalyst.rawValue == "ios-maccatalyst")
    }

    @Test
    func platformFilterString() {
        #expect(Platform.platformFilterString(from: [.iOS]) == "ios")
        #expect(
            Platform.platformFilterString(from: [.iOS, .iOSSimulator])
            == "ios;ios-simulator"
        )
        #expect(Platform.platformFilterString(from: [.macOS]) == "macos")
        #expect(
            Platform.platformFilterString(from: [.tvOS, .tvOSSimulator])
            == "tvos;tvos-simulator"
        )
        #expect(
            Platform.platformFilterString(from: [.watchOS, .watchOSSimulator, .visionOS, .visionOSSimulator])
            == "watchos;watchos-simulator;visionos;visionos-simulator"
        )
        #expect(Platform.platformFilterString(from: []) == "")
    }
}
