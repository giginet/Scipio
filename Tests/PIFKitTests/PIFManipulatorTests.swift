import Foundation
import Testing
@testable import PIFKit

@Suite
struct PIFManipulatorTests {
    @Test
    func canUpdateBuildConfiguration() throws {
        let jsonData = try #require(FixtureLoader.load(named: "SimplePackage.pif"))
        let fixtureString = try #require(String(data: jsonData, encoding: .utf8))
        let manipulator = try PIFManipulator(jsonData: jsonData)
        
        #expect(!fixtureString.contains("MY_VALUE"))
        
        var detectedTargets: [String] = []
        try manipulator.updateBuildSettings { context in
            detectedTargets.append(context.targetName)
            
            var modified = context.buildConfiguration
            modified.buildSettings["MY_VALUE"] = "TEST"
            
            return modified
        }
        
        let dumpedData = try manipulator.dump()
        let dumpedString = try #require(String(data: dumpedData, encoding: .utf8))
        
        #expect(dumpedString.contains("MY_VALUE"))
        #expect(detectedTargets.count == 10)
    }
}
