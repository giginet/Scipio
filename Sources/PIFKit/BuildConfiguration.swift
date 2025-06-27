import Foundation
import SwiftyJSON

/// A model representing a build configuration on PIF.
/// This implementation based on the following implementation:
/// https://github.com/swiftlang/swift-package-manager/blob/70862aa31255de0b9240826bfddaa1bb92cefb05/Sources/XCBuildSupport/PIF.swift#L869-L897
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

extension BuildConfiguration.MacroExpressionValue? {
    package mutating func append(_ appendingValues: [String]) {
        self = .stringList(self.values + appendingValues)
    }

    package mutating func append(_ appendingValue: String) {
        append([appendingValue])
    }

    private var values: [String] {
        switch self {
        case .bool(let value):
            return [value ? "YES" : "NO"]
        case .string(let value):
            return [value]
        case .stringList(let value):
            return value
        case .none:
            return ["$(inherited)"]
        }
    }
}

extension [String: BuildConfiguration.MacroExpressionValue] {
    /// Sets a build setting value with an optional platform filter
    /// Example: buildSettings["FRAMEWORK_SEARCH_PATHS", for: [.iOS, .iOSSimulator]] = .stringList(["path1", "path2"])
    package subscript(key: String, for platforms: [Platform]) -> BuildConfiguration.MacroExpressionValue? {
        get {
            let platformFilterKey = "\(key)[__platform_filter=\(platforms.settingValue)]"
            return self[platformFilterKey]
        }
        set {
            let platformFilterKey = "\(key)[__platform_filter=\(platforms.settingValue)]"
            self[platformFilterKey] = newValue
        }
    }
}
