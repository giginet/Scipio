import Foundation
import SwiftyJSON

package class PIFManipulator {
    private var topLevelObject: JSON
    
    package init(jsonData: Data) throws {
        self.topLevelObject = try JSON(data: jsonData)
    }
    
    package func updateTargets(_ modifier: (inout Target) -> Void) throws {
        for (index, pifObject) in topLevelObject.arrayValue.enumerated() {
            guard pifObject["type"].stringValue == "target", var target = try? Target(from: pifObject["contents"]) else {
                continue
            }
            
            modifier(&target)
            topLevelObject[index]["contents"]["productTypeIdentifier"].string = target.productType?.rawValue
            topLevelObject[index]["contents"]["buildConfigurations"].arrayObject = target.buildConfigurations.compactMap { try? $0.toJSON() }
        }
    }
    
    package func dump() throws -> Data {
        try topLevelObject.rawData(options: [.prettyPrinted])
    }
}

extension BuildConfiguration {
    fileprivate func toJSON(using encoder: JSONEncoder = JSONEncoder()) throws -> JSON {
        let data = try encoder.encode(self)
        return try JSON(data: data)
    }
}
