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
    func platformSettingValue() {
        #expect([Platform.iOS].settingValue == "ios")
        #expect([Platform.iOS, .iOSSimulator].settingValue == "ios;ios-simulator")
        #expect([Platform.macOS].settingValue == "macos")
        #expect([Platform.tvOS, .tvOSSimulator].settingValue == "tvos;tvos-simulator")
        #expect(
            [Platform.watchOS, .watchOSSimulator, .visionOS, .visionOSSimulator].settingValue
            == "watchos;watchos-simulator;visionos;visionos-simulator"
        )
        #expect([Platform]().settingValue == "")
    }
}
