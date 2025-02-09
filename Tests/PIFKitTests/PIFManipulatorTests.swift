import Foundation
import Testing
@testable import PIFKit

@Suite
struct PIFManipulatorTests {
    @Test
    func canUpdateProductTypes() throws {
        let jsonData = try #require(FixtureLoader.load(named: "SimplePackage.pif"))
        let manipulator = try PIFManipulator(jsonData: jsonData)
        
        var detectedTargets: [String] = []
        try manipulator.updateTargets { target in
            detectedTargets.append(target.name)
            
            var modified = target
            modified.productType = .application
            
            return modified
        }
        
        let dumpedData = try manipulator.dump()
        let dumpedString = try #require(String(data: dumpedData, encoding: .utf8))
        
        #expect(dumpedString.contains("product-type.application"))
        #expect(detectedTargets.count == 5)
    }
    
    @Test
    func canUpdateBuildConfiguration() throws {
        let jsonData = try #require(FixtureLoader.load(named: "SimplePackage.pif"))
        let fixtureString = try #require(String(data: jsonData, encoding: .utf8))
        let manipulator = try PIFManipulator(jsonData: jsonData)
        
        #expect(!fixtureString.contains("MY_VALUE"))
        
        try manipulator.updateTargets { target in
            var modified = target
            
            modified.buildConfigurations[0].buildSettings["MY_VALUE"] = "YES"
            modified.buildConfigurations[1].buildSettings["MY_VALUE"] = "YES"
            
            return modified
        }
        
        let dumpedData = try manipulator.dump()
        let dumpedString = try #require(String(data: dumpedData, encoding: .utf8))
        
        #expect(dumpedString.contains("MY_VALUE"))
    }
}
