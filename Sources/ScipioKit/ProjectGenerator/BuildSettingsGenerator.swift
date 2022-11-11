import Foundation
import PackageGraph
import class PackageModel.SwiftTarget
import struct PackageModel.SwiftLanguageVersion
import class PackageModel.SystemLibraryTarget
import class PackageModel.ClangTarget
import TSCBasic
import XcodeProj

enum XCConfigValue {
    case string(String)
    case list([XCConfigValue])
    case bool(Bool)

    static let inherited: Self = .string("$(inherited)")

    var rawString: String {
        switch self {
        case .string(let rawString): return rawString
        case .bool(let bool): return bool ? "YES" : "NO"
        case .list(let list): return list.map(\.rawString).joined(separator: " ")
        }
    }
}

extension XCConfigValue {
    func appending(_ value: XCConfigValue) -> Self {
        switch self {
        case .string, .bool:
            return .list([self, value])
        case .list(let currentList):
            return .list(currentList + [value])
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

struct ProjectBuildSettingsGenerator {
    func generate(configuration: BuildConfiguration) -> XCBuildConfiguration {
        let baseSettings: BuildSettings = commonBuildSettings

        // TODO C Flags

        // TODO Distribution settings

        let specificSettings: BuildSettings
        switch configuration {
        case .debug:
            specificSettings = debugSpecificSettings
        case .release:
            specificSettings = releaseSpecificSettings
        }

        return .init(
            name: configuration.settingsValue,
            buildSettings:
                baseSettings.merging(specificSettings) { $1 }
        )
    }

    private var commonBuildSettings: BuildSettings {
        let values: [String: XCConfigValue] = [
            "PRODUCT_NAME": "$(TARGET_NAME)",
            "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
            "SUPPORTS_MACCATALYST": true,
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
        return values.mapValues(\.rawString)
    }

    private var debugSpecificSettings: BuildSettings {
        let specificSettings: [String: XCConfigValue] = [
            "COPY_PHASE_STRIP": false,
            "DEBUG_INFORMATION_FORMAT": "dwarf",
            "ENABLE_NS_ASSERTIONS": true,
            "GCC_OPTIMIZATION_LEVEL": "0",
            "GCC_PREPROCESSOR_DEFINITIONS": [.inherited, "DEBUG=1"],
            "ONLY_ACTIVE_ARCH": true,
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": [.inherited, "DEBUG"],
        ]
        return specificSettings.mapValues(\.rawString)
    }

    private var releaseSpecificSettings: BuildSettings {
        let specificSettings: [String: XCConfigValue] = [
            "COPY_PHASE_STRIP": true,
            "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
            "GCC_OPTIMIZATION_LEVEL": "s",
            "SWIFT_OPTIMIZATION_LEVEL": "-Owholemodule",
        ]
        return specificSettings.mapValues(\.rawString)
    }
}

struct TargetBuildSettingsGenerator {
    private let package: Package
    private let isDebugSymbolsEmbedded: Bool
    private let isStaticFramework: Bool

    init(package: Package, isDebugSymbolsEmbedded: Bool, isStaticFramework: Bool) {
        self.package = package
        self.isDebugSymbolsEmbedded = isDebugSymbolsEmbedded
        self.isStaticFramework = isStaticFramework
    }

    private var sourceRootDir: AbsolutePath {
        package.graph.rootPackages[0].path
    }

    func generate(for target: ResolvedTarget, configuration: BuildConfiguration, infoPlistPath: URL) -> XCBuildConfiguration {
        var settings: [String: XCConfigValue] = [
            "TARGET_NAME": .string(target.name),
            "INFOPLIST_FILE": .string(infoPlistPath.relativePath),
            "CURRENT_PROJECT_VERSION": "1",
            "LD_RUNPATH_SEARCH_PATHS": [.inherited, "$(TOOLCHAIN_DIR)/usr/lib/swift/macosx"],
            "OTHER_CFLAGS": [.inherited],
            "OTHER_LDFLAGS": [.inherited],
            "OTHER_SWIFT_FLAGS": [.inherited],
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": [.inherited],
            "FRAMEWORK_SEARCH_PATHS": [.inherited, "$(PLATFORM_DIR)/Developer/Library/Frameworks"],
            "BUILD_LIBRARY_FOR_DISTRIBUTION": true,
        ]

        for supportedPlatform in target.platforms.derived {
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
                "LD_RUNPATH_SEARCH_PATHS": [.inherited, "@loader_path/../Frameworks", "@loader_path/Frameworks"]
            ])
        default:
            settings.merge([
                "SWIFT_FORCE_STATIC_LINK_STDLIB": false,
                "SWIFT_FORCE_DYNAMIC_LINK_STDLIB": true,
                "LD_RUNTIME_SEARCH_PATH": [.inherited, "$(TOOLCHAIN_DIR)/usr/lib/swift/macosx", "@executable_path"]
            ])
        }

        if let swiftTarget = target.underlyingTarget as? SwiftTarget {
            settings["SWIFT_VERSION"] = .string(swiftTarget.swiftVersion.xcodeBuildSettingValue)
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
            buildSettings: settings.mapValues(\.rawString)
        )
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
//                for pkgArgs in pkgConfigArgs(for: systemTarget, fileSystem: fileSystem, observabilityScope: observabilityScope) {
//                    targetSettings.common.OTHER_LDFLAGS += pkgArgs.libs
//                    targetSettings.common.OTHER_SWIFT_FLAGS += pkgArgs.cFlags
//                    targetSettings.common.OTHER_CFLAGS += pkgArgs.cFlags
//                }
            case let clangTarget as ClangTarget:
                headerSearchPaths.append("$(SRCROOT)/\(clangTarget.includeDir.relative(to: sourceRootDir).pathString)")
              default:
                continue
            }
        }
        return headerSearchPaths
    }
}

extension Dictionary {
    fileprivate func merging(_ other: Self) -> Self {
        self.merging(other, uniquingKeysWith: { $1 })
    }

    fileprivate mutating func merge(_ other: Self) {
        self.merge(other, uniquingKeysWith: { $1 })
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
