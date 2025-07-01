import Foundation
import Testing
@testable import PIFKit

@Suite
struct BuildConfigurationTests {
    @Test
    func canParseBuildConfiguration() throws {
        let fixtureData = try FixtureLoader.load(named: "BuildConfiguration.json")
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
        let fixtureData = try FixtureLoader.load(named: "BuildConfiguration.json")
        let decoder = JSONDecoder()
        let configuration = try decoder.decode(BuildConfiguration.self, from: fixtureData)

        let encoder = JSONEncoder()
        let encoded = try encoder.encode(configuration)

        let redecoded = try decoder.decode(BuildConfiguration.self, from: encoded)
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

    @Test(arguments: [
        (
            "FRAMEWORK_SEARCH_PATHS",
            [Platform.iOS, .iOSSimulator],
            BuildConfiguration.MacroExpressionValue.stringList(["path1", "path2"]),
            "FRAMEWORK_SEARCH_PATHS[__platform_filter=ios;ios-simulator]"
        ),
        (
            "OTHER_LDFLAGS",
            [Platform.macOS],
            BuildConfiguration.MacroExpressionValue.string("-framework Foundation"),
            "OTHER_LDFLAGS[__platform_filter=macos]"
        ),
        (
            "SUPPORTED_PLATFORMS",
            [Platform.tvOS, .tvOSSimulator, .watchOS, .watchOSSimulator],
            BuildConfiguration.MacroExpressionValue.stringList([
                "tvos", "tvossimulator", "watchos", "watchossimulator"
            ]),
            "SUPPORTED_PLATFORMS[__platform_filter=tvos;tvos-simulator;watchos;watchos-simulator]"
        )
    ])
    func platformFilterSubscript(
        key: String,
        platforms: [Platform],
        value: BuildConfiguration.MacroExpressionValue,
        expectedKey: String
    ) {
        var buildSettings: [String: BuildConfiguration.MacroExpressionValue] = [:]

        // Test setting value with platform filter
        buildSettings[key, for: platforms] = value

        // Verify the key is constructed correctly
        #expect(buildSettings[expectedKey] == value)

        // Test getting value with platform filter
        let retrievedValue = buildSettings[key, for: platforms]
        #expect(retrievedValue == value)
    }
}
