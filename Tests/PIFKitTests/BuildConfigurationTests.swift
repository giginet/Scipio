import Foundation
import Testing
@testable import PIFKit

@Suite
struct BuildConfigurationTests {
    @Test
    func canParseBuildConfiguration() throws {
        let fixtureData = try #require(FixtureLoader.load(named: "BuildConfiguration.json"))
        let decoder = JSONDecoder()
        let configuration = try decoder.decode(BuildConfiguration.self, from: fixtureData)

        #expect(configuration.name == "Debug")
        #expect(configuration.buildSettings["CLANG_ENABLE_OBJC_ARC"] == true)
        #expect(configuration.buildSettings["SWIFT_INSTALL_OBJC_HEADER"] == false)
        #expect(configuration.buildSettings["DEBUG_INFORMATION_FORMAT"] == "dwarf")
        #expect(
            configuration.buildSettings["FRAMEWORK_SEARCH_PATHS[__platform_filter=ios;ios-simulator]"] ==
            ["$(inherited)", "$(PLATFORM_DIR)/Developer/Library/Frameworks"]
        )
        #expect(configuration.impartedBuildProperties.buildSettings.isEmpty)
    }

    @Test
    func roundTrip() throws {
        let fixtureData = try #require(FixtureLoader.load(named: "BuildConfiguration.json"))
        let decoder = JSONDecoder()
        let configuration = try decoder.decode(BuildConfiguration.self, from: fixtureData)

        let encoder = JSONEncoder()
        _ = try String(data: encoder.encode(configuration), encoding: .utf8)

        let redecoded = try decoder.decode(BuildConfiguration.self, from: fixtureData)
        #expect(configuration == redecoded)
    }

    private static let appendingFixtures: [(BuildConfiguration.MacroExpressionValue?, [String])] = [
        (.bool(false), ["NO", "added"]),
        (.bool(true), ["YES", "added"]),
        (.string("foo"), ["foo", "added"]),
        (.stringList(["foo", "bar"]), ["foo", "bar", "added"]),
        (nil, ["$(inherited)", "added"]),
    ]
    @Test("can append flags", arguments: appendingFixtures)
    func appending(setting: BuildConfiguration.MacroExpressionValue?, expected: [String]) {
        var mutableSetting = setting
        mutableSetting.append("added")
        #expect(mutableSetting == .stringList(expected))
    }
}
