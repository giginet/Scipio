import Foundation
import SwiftyJSON

package struct BuildConfiguration: Codable, Equatable, JSONConvertible {
    package enum MacroExpressionValue: Sendable, Codable, Equatable {
        case bool(Bool)
        case string(String)
        case stringList([String])
    }
    
    package struct ImpartedBuildProperties: Sendable, Codable, Equatable {
        package var buildSettings: [String: MacroExpressionValue]

        package init(buildSettings: [String: MacroExpressionValue]) {
            self.buildSettings = buildSettings
        }
    }

    package var name: String
    package var buildSettings: [String: MacroExpressionValue]
    package var baseConfigurationFileReferenceGUID: String?
    package var impartedBuildProperties: ImpartedBuildProperties
}


extension BuildConfiguration.MacroExpressionValue {
    package enum DecodingError: Error {
        case unknownBuildSettingsValue
    }
    
    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value):
            try container.encode(value ? "YES" : "NO")
        case .string(let value):
            try container.encode(value)
        case .stringList(let value):
            try container.encode(value)
        }
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

extension BuildConfiguration.MacroExpressionValue: ExpressibleByStringLiteral {
    package init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension BuildConfiguration.MacroExpressionValue: ExpressibleByBooleanLiteral {
    package init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension BuildConfiguration.MacroExpressionValue: ExpressibleByArrayLiteral {
    package init(arrayLiteral elements: String...) {
        self = .stringList(elements)
    }
}
