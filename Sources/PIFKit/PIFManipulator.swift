import Foundation
import SwiftyJSON

/// Manipulates PIF JSON data
package final class PIFManipulator {
    private var topLevelObject: JSON

    /// Initialize PIFManipulator with JSON data
    /// - Parameters jsonData: JSON data
    package init(jsonData: Data) throws {
        self.topLevelObject = try JSON(data: jsonData)
    }

    /// Update targets in PIF JSON data
    /// - Parameters modifier: Closure to modify Target
    package func updateTargets(_ modifier: (inout Target) async -> Void) async {
        for index in 0..<topLevelObject.arrayValue.count {
            guard topLevelObject[index]["type"].stringValue == "target", var target = try? Target(from: topLevelObject[index]["contents"]) else {
                continue
            }

            await modifier(&target)
            apply(target, to: &topLevelObject[index])
        }
    }

    /// Dump manipulating JSON data
    /// - Returns: JSON data
    package func dump() throws -> Data {
        try topLevelObject.rawData(options: [.prettyPrinted])
    }

    /// Apply target to JSON object
    /// Currently, Target is a subset of an actual PIF target. So, we have to apply only the properties that are present in the Target.
    /// - Parameters target: Target to apply
    /// - Parameters pifObject: JSON object to apply the target to
    private func apply(_ target: Target, to pifObject: inout JSON) {
        pifObject["contents"]["name"].string = target.name
        pifObject["contents"]["productTypeIdentifier"].string = target.productType?.rawValue

        let jsonEncoder = JSONEncoder()
        pifObject["contents"]["buildConfigurations"].arrayObject = target.buildConfigurations.compactMap { try? $0.toJSON(using: jsonEncoder) }
    }
}

extension BuildConfiguration {
    fileprivate func toJSON(using encoder: JSONEncoder = JSONEncoder()) throws -> JSON {
        let data = try encoder.encode(self)
        return try JSON(data: data)
    }
}
