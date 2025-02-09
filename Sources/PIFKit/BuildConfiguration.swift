import Foundation
import SwiftyJSON

package struct BuildConfiguration: Codable {
    package enum MacroExpressionValue: Sendable, Codable, Equatable {
        case bool(Bool)
        case string(String)
        case stringList([String])
    }
    
    package struct ImpartedBuildProperties: Sendable, Codable {
        package let buildSettings: [String: MacroExpressionValue]

        package init(buildSettings: [String: MacroExpressionValue]) {
            self.buildSettings = buildSettings
        }
    }

    package let name: String
    package let buildSettings: [String: MacroExpressionValue]
    package let baseConfigurationFileReferenceGUID: String?
    package let impartedBuildProperties: ImpartedBuildProperties
}



extension BuildConfiguration.MacroExpressionValue {
    package enum DecodingError: Error {
        case unknownBuildSettingsValue
    }
    
    fileprivate var settingsValue: String {
        switch self {
        case .bool(let value):
            return value ? "YES" : "NO"
        case .string(let value):
            return value
        case .stringList(let value):
            return value.joined(separator: " ")
        }
    }
    
    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(settingsValue)
    }
    
    package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let stringValue = try? container.decode(String.self) {
            if stringValue == "YES" {
                self = .bool(true)
            } else if stringValue == "NO" {
                self = .bool(false)
            } else {
                self = .string(stringValue)
            }
        } else if let arrayValue = try? container.decode([String].self) {
            self = .stringList(arrayValue)
        } else {
            throw DecodingError.unknownBuildSettingsValue
        }
    }
}

extension BuildConfiguration {
    init(from json: JSON) throws {
        let decoder = JSONDecoder()
        let data = try json.rawData()
        self = try decoder.decode(BuildConfiguration.self, from: data)
    }
}
