import Foundation

public struct BuildOptions: Hashable {
    public init(tag: String? = nil, buildConfiguration: BuildConfiguration, isSimulatorSupported: Bool, isDebugSymbolsEmbedded: Bool) {
        self.tag = tag
        self.buildConfiguration = buildConfiguration
        self.isSimulatorSupported = isSimulatorSupported
        self.isDebugSymbolsEmbedded = isDebugSymbolsEmbedded
    }

    public var tag: String?
    public var buildConfiguration: BuildConfiguration
    public var isSimulatorSupported: Bool
    public var isDebugSymbolsEmbedded: Bool
}

enum SDK {
    case macOS
    case macCatalyst
    case iOS
    case iOSSimulator
    case tvOS
    case tvOSSimulator
    case watchOS
    case watchOSSimulator

    func extractForSimulators() -> Set<SDK> {
        switch self {
        case .macOS: return [.macOS]
        case .iOS: return [.iOS, .iOSSimulator]
        case .tvOS: return [.tvOS, .tvOSSimulator]
        case .watchOS: return [.watchOS, .watchOSSimulator]
        default: return [self]
        }
    }

    var name: String {
        switch self {
        case .macOS:
            return "macos"
        case .macCatalyst:
            return "maccatalyst"
        case .iOS:
            return "iphoneos"
        case .iOSSimulator:
            return "iphonesimulator"
        case .tvOS:
            return "appletvos"
        case .tvOSSimulator:
            return "appletvsimulator"
        case .watchOS:
            return "watchos"
        case .watchOSSimulator:
            return "watchsimulator"
        }
    }

    var destination: String {
        switch self {
        case .macOS:
            return "generic/platform=macOS,name=Any Mac"
        case .macCatalyst:
            return "generic/platform=macOS,variant=Mac Catalyst"
        case .iOS:
            return "generic/platform=iOS"
        case .iOSSimulator:
            return "generic/platform=iOS Simulator"
        case .tvOS:
            return "generic/platform=tvOS"
        case .tvOSSimulator:
            return "generic/platform=tvOS Simulator"
        case .watchOS:
            return "generic/platform=watchOS"
        case .watchOSSimulator:
            return "generic/platform=watchOS Simulator"
        }
    }
}
