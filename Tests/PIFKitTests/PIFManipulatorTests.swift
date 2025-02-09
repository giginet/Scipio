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
        manipulator.updateTargets { target in
            detectedTargets.append(target.name)

            target.productType = .application
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

        manipulator.updateTargets { target in
            target.buildConfigurations[0].buildSettings["MY_VALUE"] = "YES"
            target.buildConfigurations[1].buildSettings["MY_VALUE"] = "YES"
        }

        let dumpedData = try manipulator.dump()
        let dumpedString = try #require(String(data: dumpedData, encoding: .utf8))

        #expect(dumpedString.contains("MY_VALUE"))
    }
}
