import Foundation
import OrderedCollections

struct BuildOptions: Hashable, Codable {
    init(
        buildConfiguration: BuildConfiguration,
        isDebugSymbolsEmbedded: Bool,
        frameworkType: FrameworkType,
        sdks: OrderedSet<SDK>,
        extraFlags: ExtraFlags?,
        extraBuildParameters: ExtraBuildParameters?,
        enableLibraryEvolution: Bool
    ) {
        self.buildConfiguration = buildConfiguration
        self.isDebugSymbolsEmbedded = isDebugSymbolsEmbedded
        self.frameworkType = frameworkType
        self.sdks = sdks
        self.extraFlags = extraFlags
        self.extraBuildParameters = extraBuildParameters
        self.enableLibraryEvolution = enableLibraryEvolution
    }

    var buildConfiguration: BuildConfiguration
    var isDebugSymbolsEmbedded: Bool
    var frameworkType: FrameworkType
    var sdks: OrderedSet<SDK>
    var extraFlags: ExtraFlags?
    var extraBuildParameters: ExtraBuildParameters?
    var enableLibraryEvolution: Bool
}

public struct ExtraFlags: Hashable, Codable {
    public var cFlags: [String]?
    public var cxxFlags: [String]?
    public var swiftFlags: [String]?
    public var linkerFlags: [String]?

    public init(
        cFlags: [String]? = nil,
        cxxFlags: [String]? = nil,
        swiftFlags: [String]? = nil,
        linkerFlags: [String]? = nil
    ) {
        self.cFlags = cFlags
        self.cxxFlags = cxxFlags
        self.swiftFlags = swiftFlags
        self.linkerFlags = linkerFlags
    }
}

public typealias ExtraBuildParameters = [String: String]

public enum BuildConfiguration: String, Codable {
    case debug
    case release

    var settingsValue: String {
        switch self {
        case .debug: return "Debug"
        case .release: return "Release"
        }
    }
}

public enum FrameworkType: String, Codable {
    case dynamic
    case `static`
}

enum SDK: String, Codable {
    case macOS
    case macCatalyst
    case iOS
    case iOSSimulator
    case tvOS
    case tvOSSimulator
    case watchOS
    case watchOSSimulator

    init?(platformName: String) {
        switch platformName {
        case "macos":
            self = .macOS
        case "ios":
            self = .iOS
        case "maccatalyst":
            self = .macCatalyst
        case "tvos":
            self = .tvOS
        case "watchos":
            self = .watchOS
        default:
            return nil
        }
    }

    func extractForSimulators() -> Set<SDK> {
        switch self {
        case .macOS: return [.macOS]
        case .iOS: return [.iOS, .iOSSimulator]
        case .tvOS: return [.tvOS, .tvOSSimulator]
        case .watchOS: return [.watchOS, .watchOSSimulator]
        default: return [self]
        }
    }

    var displayName: String {
        switch self {
        case .macOS:
            return "macOS"
        case .macCatalyst:
            return "Catalyst"
        case .iOS:
            return "iOS"
        case .iOSSimulator:
            return "iPhone Simulator"
        case .watchOS:
            return "watchOS"
        case .watchOSSimulator:
            return "Watch Simulator"
        case .tvOS:
            return "tvOS"
        case .tvOSSimulator:
            return "TV Simulator"
        }
    }

    var settingValue: String {
        switch self {
        case .macOS:
            return "macosx"
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

extension ExtraFlags {
    func concatenating(_ otherExtraFlags: Self?) -> Self {
        func concatenating(_ key: KeyPath<Self, [String]?>) -> [String]? {
            return (self[keyPath: key] ?? []) + (otherExtraFlags?[keyPath: key] ?? [])
        }

        return .init(
            cFlags: concatenating(\.cFlags),
            cxxFlags: concatenating(\.cxxFlags),
            swiftFlags: concatenating(\.swiftFlags),
            linkerFlags: concatenating(\.linkerFlags)
        )
    }
}
