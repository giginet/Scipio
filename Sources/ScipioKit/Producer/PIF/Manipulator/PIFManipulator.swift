import Foundation

enum PIFObjectType: String {
    case workspace
    case project
    case target
    case file
    case group
}

protocol PIFObject {
    associatedtype Contents: Codable
    
    var signature: String { get }
    var type: PIFObjectType { get }
    var contents: Contents { get }
}

struct PIFWorkspace {
    struct PIFProject {
        struct PIFTarget {
        }
    }
}

protocol PIFManipulation {
    func modifyTarget(topLevelObject: [[String: Any]]) -> Any
    func modify(object: inout Any)
}

final class ScipioPIF {
    enum PIFError: Error {
        case unexpectedFormat
    }
    fileprivate var topLevelObject: [[String: Any]]
    
    init(jsonData: Data) throws {
        guard let rawJSONObject = try? JSONSerialization.jsonObject(with: jsonData, options: .mutableContainers),
        let topLevelObject = rawJSONObject as? [[String: Any]] else {
            throw PIFError.unexpectedFormat
        }
        self.topLevelObject = topLevelObject
    }
    
    func object(by signature: String) -> Any? {
        topLevelObject.first { object in
            object["signature"] as? String == signature
        }
    }
    
    func dump() throws -> Data {
        try JSONSerialization.data(withJSONObject: topLevelObject)
    }
}

struct PIFManipulator {
    private let pif: ScipioPIF
    
    init(pif: ScipioPIF) {
        self.pif = pif
    }
    
    struct UpdateTargetBuildConfigurationContext {
        var targetName: String
        var buildConfiguration: [String: Any]
    }
    
    func updateTargetBuildConfigurations(_ modifier: (UpdateTargetBuildConfigurationContext) -> [String: Any]) {
        var mutableTopLevelObject = pif.topLevelObject
        for var object in mutableTopLevelObject {
            guard let pifObjectType = (object["type"] as? String), pifObjectType == "target" else {
                continue
            }
            guard let targetName = object["name"] as? String else {
                continue
            }
            let context = UpdateTargetBuildConfigurationContext(
                targetName: targetName,
                buildConfiguration: object.dig("buildConfigurations") ?? [:]
            )
            let newConfiguration = modifier(context)
            object["buildConfigurations"] = newConfiguration
        }
    }
}

extension [String: Any] {
    func dig<T>(_ keys: String...) -> T? {
        var current: Any? = self
        
        for key in keys {
            guard let dictionary = current as? [String: Any],
                  let value = dictionary[key] else {
                return nil
            }
            current = value
        }
        
        return current as? T
    }
}
