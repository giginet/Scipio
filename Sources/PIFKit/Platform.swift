import Foundation

/// Represents platforms that can be used in PIF platform filters
package enum Platform: String, CaseIterable, Sendable {
    case iOS = "ios"
    case iOSSimulator = "ios-simulator"
    case macOS = "macos"
    case tvOS = "tvos"
    case tvOSSimulator = "tvos-simulator"
    case watchOS = "watchos"
    case watchOSSimulator = "watchos-simulator"
    case visionOS = "visionos"
    case visionOSSimulator = "visionos-simulator"
    case macCatalyst = "ios-maccatalyst"
}

extension Array where Element == Platform {
    /// The platform filter string format used in PIF build settings
    /// For example: [.iOS, .iOSSimulator] -> "ios;ios-simulator"
    package var settingValue: String {
        map(\.rawValue).joined(separator: ";")
    }
}
