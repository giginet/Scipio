import Foundation
import XcodeProj

struct XCConfigValue {
    let rawString: String
}

extension XCConfigValue: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: BooleanLiteralType) {
        self.rawString = value ? "YES" : "NO"
    }
}

extension XCConfigValue: ExpressibleByStringLiteral {
    init(stringLiteral value: StringLiteralType) {
        self.rawString = value
    }
}

extension XCConfigValue: ExpressibleByArrayLiteral {
    typealias ArrayLiteralElement = String

    init(arrayLiteral elements: ArrayLiteralElement...) {
        self.rawString = elements.joined(separator: " ")
    }
}

struct BuildSettingsGenerator {
    func generate(for configuration: BuildConfiguration) -> XCBuildConfiguration {
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
            "OTHER_SWIFT_FLAGS": ["$(inherited)", "-DXcode"],
            "MACOSX_DEPLOYMENT_TARGET": "10.10",
            "COMBINE_HIDPI_IMAGES": true,
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": ["$(inherited)", "SWIFT_PACKAGE"],
            "GCC_PREPROCESSOR_DEFINITIONS": ["$(inherited)", "SWIFT_PACKAGE=1"],
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
            "GCC_PREPROCESSOR_DEFINITIONS": ["$(inherited)", "DEBUG=1"],
            "ONLY_ACTIVE_ARCH": true,
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": ["$(inherited)", "DEBUG"],
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
