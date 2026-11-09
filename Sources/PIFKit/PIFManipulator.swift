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
    package func updateTargets(_ modifier: (inout Target) -> Void) {
        for index in 0..<topLevelObject.arrayValue.count {
            guard topLevelObject[index]["type"].stringValue == "target", var target = try? Target(from: topLevelObject[index]["contents"]) else {
                continue
            }

            modifier(&target)
            apply(target, to: &topLevelObject[index])
        }
    }

    package func removeHostMacroDependencies(_ namesByTarget: [String: Set<String>]) {
        let targets = topLevelObject.arrayValue.filter { $0["type"].stringValue == "target" }
        for index in 0..<topLevelObject.arrayValue.count where topLevelObject[index]["type"].stringValue == "target" {
            let contents = topLevelObject[index]["contents"]
            let targetName = contents["name"].stringValue
            guard let (_, names) = namesByTarget.sorted(by: { $0.key.count > $1.key.count }).first(where: { name, _ in
                targetName == name || (targetName.hasPrefix("\(name)_") && targetName.hasSuffix("_PackageProduct"))
            }) else { continue }

            var guids: Set<String> = []
            for candidate in targets {
                let candidateName = candidate["contents"]["name"].stringValue
                if names.contains(candidateName) || names.contains(where: {
                    candidateName.hasPrefix("\($0)_") && candidateName.hasSuffix("_PackageProduct")
                }) {
                    guids.insert(candidate["contents"]["guid"].stringValue)
                }
            }
            func isHostReference(_ guid: String) -> Bool {
                guids.contains(guid) || names.contains {
                    guid == "PACKAGE-TARGET:\($0)" || guid.hasPrefix("PACKAGE-TARGET:\($0)@")
                }
            }
            if let dependencies = contents["dependencies"].array {
                topLevelObject[index]["contents"]["dependencies"].arrayObject = dependencies
                    .filter { !isHostReference($0["guid"].stringValue) }.map(\.object)
            }
            if let phases = contents["buildPhases"].array {
                var updated = phases
                for phaseIndex in updated.indices {
                    guard let files = updated[phaseIndex]["buildFiles"].array else { continue }
                    updated[phaseIndex]["buildFiles"].arrayObject = files
                        .filter { !isHostReference($0["targetReference"].stringValue) }.map(\.object)
                }
                topLevelObject[index]["contents"]["buildPhases"].arrayObject = updated.map(\.object)
            }
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
