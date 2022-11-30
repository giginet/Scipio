import Foundation
import PackageGraph
import class PackageModel.SwiftTarget
import struct PackageModel.SwiftLanguageVersion
import class PackageModel.SystemLibraryTarget
import class PackageModel.ClangTarget
import struct PackageModel.Platform
import struct PackageModel.SupportedPlatform
import TSCBasic
import XcodeProj

private enum XCConfigValue {
    case string(String)
    case list([XCConfigValue])
    case bool(Bool)

    static let inherited: Self = .string("$(inherited)")

    var rawConfigValue: Any {
        switch self {
        case .string(let rawString): return rawString
        case .bool(let bool): return bool
        case .list(let list): return list.map(\.rawConfigValue)
        }
    }
}

extension XCConfigValue: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: BooleanLiteralType) {
        self = .bool(value)
    }
}

extension XCConfigValue: ExpressibleByStringLiteral {
    init(stringLiteral value: StringLiteralType) {
        self = .string(value)
    }
}

extension XCConfigValue: ExpressibleByArrayLiteral {
    typealias ArrayLiteralElement = XCConfigValue

    init(arrayLiteral elements: ArrayLiteralElement...) {
        self = .list(elements)
    }
}

private enum TargetDeviceFamily: Int {
    case iPhone = 1
    case iPad = 2
    case appleTV = 3
    case appleWatch = 4
}

struct ProjectBuildSettingsGenerator {
    func generate(configuration: BuildConfiguration) -> XCBuildConfiguration {
        var settings = commonBuildSettings

        switch configuration {
        case .debug:
            settings.merge(debugSpecificSettings)
        case .release:
            settings.merge(releaseSpecificSettings)
        }

        return .init(
            name: configuration.settingsValue,
            buildSettings: settings.mapValues(\.rawConfigValue)
        )
    }

    private var commonBuildSettings: [String: XCConfigValue] {
        [
            "PRODUCT_NAME": "$(TARGET_NAME)",
            "SDKROOT": "macosx",
            "DYLIB_INSTALL_NAME_BASE": "@rpath",
            "OTHER_SWIFT_FLAGS": [.inherited, "-DXcode"],
            "MACOSX_DEPLOYMENT_TARGET": "10.10",
            "COMBINE_HIDPI_IMAGES": true,
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": [.inherited, "SWIFT_PACKAGE"],
            "GCC_PREPROCESSOR_DEFINITIONS": [.inherited, "SWIFT_PACKAGE=1"],
            "USE_HEADERMAP": false,
            "CLANG_ENABLE_OBJC_ARC": true,
        ]
    }

    private var debugSpecificSettings: [String: XCConfigValue] {
        [
            "COPY_PHASE_STRIP": false,
            "DEBUG_INFORMATION_FORMAT": "dwarf",
            "ENABLE_NS_ASSERTIONS": true,
            "GCC_OPTIMIZATION_LEVEL": "0",
            "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1"],
            "ONLY_ACTIVE_ARCH": true,
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": ["DEBUG"],
        ]
    }

    private var releaseSpecificSettings: [String: XCConfigValue] {
        [
            "COPY_PHASE_STRIP": true,
            "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
            "GCC_OPTIMIZATION_LEVEL": "s",
            "SWIFT_OPTIMIZATION_LEVEL": "-Owholemodule",
        ]
    }
}

struct TargetBuildSettingsGenerator {
    private let package: Package
    private let isDebugSymbolsEmbedded: Bool
    private let isStaticFramework: Bool
    private let isSimulatorSupported: Bool

    init(package: Package, isDebugSymbolsEmbedded: Bool, isStaticFramework: Bool, isSimulatorSupported: Bool) {
        self.package = package
        self.isDebugSymbolsEmbedded = isDebugSymbolsEmbedded
        self.isStaticFramework = isStaticFramework
        self.isSimulatorSupported = isSimulatorSupported
    }

    private var sourceRootDir: AbsolutePath {
        package.graph.rootPackages[0].path
    }

    private func baseSettings(for target: ResolvedTarget) -> [String: XCConfigValue] {
        [
            "TARGET_NAME": .string(target.name),
            "CURRENT_PROJECT_VERSION": "1",
            "LD_RUNPATH_SEARCH_PATHS": [.inherited, "$(TOOLCHAIN_DIR)/usr/lib/swift/macosx"],
            "OTHER_CFLAGS": [.inherited],
            "OTHER_LDFLAGS": [.inherited],
            "OTHER_SWIFT_FLAGS": [.inherited],
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": [.inherited],
            "FRAMEWORK_SEARCH_PATHS": [.inherited, "$(PLATFORM_DIR)/Developer/Library/Frameworks"],
            "BUILD_LIBRARY_FOR_DISTRIBUTION": true,
        ]
    }

    func generate(for target: ResolvedTarget, configuration: BuildConfiguration, infoPlistPath: URL) -> XCBuildConfiguration {
        var settings: [String: XCConfigValue] = baseSettings(for: target)
        settings["INFOPLIST_FILE"] = .string(infoPlistPath.path)

        settings.merge(platformSettings(for: target, isSimulatorSupported: isSimulatorSupported))

        switch target.type {
        case .library:
            settings.merge([
                "ENABLE_TESTABILITY": true,
                "PRODUCT_NAME": "$(TARGET_NAME:c99extidentifier)",
                "PRODUCT_MODULE_NAME": "$(TARGET_NAME:c99extidentifier)",
                "PRODUCT_BUNDLE_IDENTIFIER": .string(target.c99name.spm_mangledToBundleIdentifier()),
                "SKIP_INSTALL": true,
                "LD_RUNTIME_SEARCH_PATH": [.inherited, "$(TOOLCHAIN_DIR)/usr/lib/swift/macosx"],
            ])
        case .test:
            settings.merge([
                "CLANG_ENABLE_MODULES": true,
                "EMBEDDED_CONTENT_CONTAINS_SWIFT": true,
                "LD_RUNPATH_SEARCH_PATHS": [.inherited, "@loader_path/../Frameworks", "@loader_path/Frameworks"],
            ])
        default:
            settings.merge([
                "SWIFT_FORCE_STATIC_LINK_STDLIB": false,
                "SWIFT_FORCE_DYNAMIC_LINK_STDLIB": true,
                "LD_RUNTIME_SEARCH_PATH": [.inherited, "$(TOOLCHAIN_DIR)/usr/lib/swift/macosx", "@executable_path"],
            ])
        }

        switch target.underlyingTarget {
        case let swiftTarget as SwiftTarget:
            settings["SWIFT_VERSION"] = .string(swiftTarget.swiftVersion.xcodeBuildSettingValue)
        case let clangTarget as ClangTarget:
            settings["GCC_C_LANGUAGE_STANDARD"] = clangTarget.cLanguageStandard.map(XCConfigValue.string)
            settings["CLANG_CXX_LANGUAGE_STANDARD"] = clangTarget.cxxLanguageStandard.map(XCConfigValue.string)
            settings["DEFINES_MODULE"] = false
        default:
            break
        }

        settings["HEADER_SEARCH_PATHS"] = .list(buildHeaderSearchPaths(for: target).map(XCConfigValue.string))

        if isDebugSymbolsEmbedded {
            settings["DEBUG_INFORMATION_FORMAT"] = "dwarf-with-dsym"
        }

        if isStaticFramework {
            settings["MACH_O_TYPE"] = "staticlib"
        }

        return .init(
            name: configuration.settingsValue,
            buildSettings: settings.mapValues(\.rawConfigValue)
        )
    }

    private func platformSettings(for target: ResolvedTarget, isSimulatorSupported: Bool) -> [String: XCConfigValue] {
        var settings: [String: XCConfigValue] = [:]

        // If platforms are not specified on target's manifests
        // Treat it supports all platforms
        let supportedPlatforms = target.platforms.declared.isEmpty ? target.platforms.derived : target.platforms.declared

        for supportedPlatform in supportedPlatforms {
            let version = XCConfigValue.string(supportedPlatform.version.versionString)
            switch supportedPlatform.platform {
            case .macOS:
                settings["MACOSX_DEPLOYMENT_TARGET"] = version
            case .iOS:
                settings["IPHONEOS_DEPLOYMENT_TARGET"] = version
            case .tvOS:
                settings["TVOS_DEPLOYMENT_TARGET"] = version
            case .watchOS:
                settings["WATCHOS_DEPLOYMENT_TARGET"] = version
            case .driverKit:
                settings["DRIVERKIT_DEPLOYMENT_TARGET"] = version
            default:
                break
            }
        }

        let targetedDeviceFamily = supportedPlatforms.map { platform -> [TargetDeviceFamily] in
            switch platform.platform {
            case .iOS: return [.iPhone, .iPad]
            case .tvOS: return [.appleTV]
            case .watchOS: return [.appleWatch]
            default: return []
            }
        }
            .flatMap { $0 }
            .map(\.rawValue)
            .sorted()
        settings["TARGETED_DEVICE_FAMILY"] = .string(targetedDeviceFamily.map(String.init).joined(separator: ","))

        let shouldSupportMacCatalyst = supportedPlatforms.map(\.platform).contains(.macCatalyst)
        settings["SUPPORTS_MACCATALYST"] = .bool(shouldSupportMacCatalyst)

        let supportedPlatformValues = buildSupportedPlatformsValue(supportedPlatforms: supportedPlatforms)
        settings["SUPPORTED_PLATFORMS"] = .string(supportedPlatformValues.joined(separator: " "))

        return settings
    }

    // Build values for SUPPORTED_PLATFORMS
    private func buildSupportedPlatformsValue(supportedPlatforms: [SupportedPlatform]) -> [String] {
        let supportedPlatformValues = supportedPlatforms.compactMap { platform in
            switch platform.platform {
            case .iOS: return "iphoneos"
            case .macOS: return "macosx"
            case .watchOS: return "watchos"
            case .tvOS: return "tvos"
            case .driverKit: return "driverkit"
            default: return nil
            }
        }

        if isSimulatorSupported {
            let supportedPlatformValuesForSimulators = supportedPlatforms.compactMap { platform in
                switch platform.platform {
                case .iOS: return "iphonesimulator"
                case .watchOS: return "watchsimulator"
                case .tvOS: return "tvsimulator"
                default: return nil
                }
            }

            return supportedPlatformValues + supportedPlatformValuesForSimulators
        }
        return supportedPlatformValues

    }

    private func buildHeaderSearchPaths(for target: ResolvedTarget) -> [String] {
        var headerSearchPaths: [String] = ["$(inherited)"]
        guard let targetDependencies = try? target.recursiveTargetDependencies() else {
            return headerSearchPaths
        }
        for dependencyModule in [target] + targetDependencies {
            switch dependencyModule.underlyingTarget {
            case let systemTarget as SystemLibraryTarget:
                headerSearchPaths.append("$(SRCROOT)/\(systemTarget.path.relative(to: sourceRootDir).pathString)")
            case let clangTarget as ClangTarget:
                headerSearchPaths.append("$(SRCROOT)/\(clangTarget.includeDir.relative(to: sourceRootDir).pathString)")
            default:
                continue
            }
        }
        return headerSearchPaths
    }
}

extension [String: XCConfigValue] {
    fileprivate mutating func merge(_ other: Self) {
        let allKeys = Set(self.keys).union(other.keys)
        for key in allKeys {
            switch (self[key], other[key]) {
            case (.some, .none):
                continue
            case (.none, .some(let rhs)):
                self[key] = rhs
            case (.some(.list(let lhs)), .some(.list(let rhs))):
                self[key] = .list(lhs + rhs)
            default:
                continue
            }
        }
    }
}

extension SwiftLanguageVersion {
    /// Returns the build setting value for the given Swift language version.
    fileprivate var xcodeBuildSettingValue: String {
        // Swift version setting are represented differently in Xcode:
        // 3 -> 3.0, 4 -> 4.0, 4.2 -> 4.2
        var swiftVersion = "\(rawValue)"
        if !rawValue.contains(".") {
            swiftVersion += ".0"
        }
        return swiftVersion
    }
}

extension BuildSettings {
    func appending(_ key: String, values: String...) -> Self {
         var newDictionary = self
         switch newDictionary[key, default: [String]()] {
         case var list as [String]:
             list.append(contentsOf: values)
             newDictionary[key] = list
         default:
             fatalError("Could not add values for \(key)")
         }
         return newDictionary
     }
}
