import Foundation
import SwiftyJSON

package class PIFManipulator {
    private var topLevelObject: JSON
    
    package init(jsonData: Data) throws {
        self.topLevelObject = try JSON(data: jsonData)
    }
    
    package func updateTargets(_ modifier: (Target) -> Target) throws {
        for (index, pifObject) in topLevelObject.arrayValue.enumerated() {
            guard pifObject["type"].stringValue == "target", let target = try? Target(from: pifObject["contents"]) else {
                continue
            }
            
            let modifiedTarget = modifier(target)
            topLevelObject[index]["contents"] = try modifiedTarget.toJSON()
        }
    }
    
    package func dump() throws -> Data {
        try topLevelObject.rawData(options: [.prettyPrinted])
    }
}
