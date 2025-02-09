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
        #expect(configuration.buildSettings["CLANG_ENABLE_OBJC_ARC"] == .bool(true))
        #expect(configuration.buildSettings["SWIFT_INSTALL_OBJC_HEADER"] == .bool(false))
        #expect(configuration.buildSettings["FRAMEWORK_SEARCH_PATHS[__platform_filter=ios;ios-simulator]"] == .stringList(["$(inherited)", "$(PLATFORM_DIR)/Developer/Library/Frameworks"]))
        #expect(configuration.impartedBuildProperties.buildSettings.isEmpty)
    }
}

