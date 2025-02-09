import Foundation
import SwiftyJSON

package class PIFManipulator {
    private var topLevelObject: JSON
    
    package init(jsonData: Data) throws {
        self.topLevelObject = try JSON(data: jsonData)
    }
    
    package struct BuildConfigurationUpdaterContext {
        package var targetName: String
        package var buildConfiguration: BuildConfiguration
    }
    
    package func updateBuildSettings(_ modifier: (BuildConfigurationUpdaterContext) -> BuildConfiguration) throws {
        for (index, pifObject) in topLevelObject.arrayValue.enumerated() {
            if pifObject["type"].stringValue == "target", let targetName = pifObject["name"].string {
                guard let buildConfigrationsJSON = pifObject["contents"]["buildConfigurations"].array else {
                    continue
                }
                let buildConfigurations = try buildConfigrationsJSON.compactMap(BuildConfiguration.init(from:))
                
                let newBuildConfigurations = try buildConfigurations.map { buildConfiguration in
                    let context = BuildConfigurationUpdaterContext(
                        targetName: targetName,
                        buildConfiguration: try BuildConfiguration(from: pifObject["buildConfiguration"])
                    )
                    return modifier(context)
                }
                topLevelObject[index]["contents"]["buildConfigurations"] = .init(try newBuildConfigurations.map { try $0.toJSON() })
            }
        }
    }
    
    package func dump() throws -> Data {
        try topLevelObject.rawData(options: [.prettyPrinted])
    }
}

extension Encodable {
    func toJSON(using encoder: JSONEncoder = JSONEncoder()) throws -> JSON {
        let data = try encoder.encode(self)
        return try JSON(data: data)
    }
}
