import Foundation
import TSCBasic
import XCBuildSupport
import SPMBuildCore

struct XCBBuildParameters: Encodable {
    struct RunDestination: Encodable {
        var platform: String
        var sdk: String
        var sdkVariant: String?
        var targetArchitecture: String
        var supportedArchitectures: [String]
        var disableOnlyActiveArch: Bool
    }

    struct XCBSettingsTable: Encodable {
        var table: [String: String]
    }

    struct SettingsOverride: Encodable {
        var synthesized: XCBSettingsTable? = nil
    }

    var configurationName: String
    var overrides: SettingsOverride
    var activeRunDestination: RunDestination
}

struct BuildParametersGenerator {
    private let fileSystem: any TSCBasic.FileSystem

    init(fileSystem: any TSCBasic.FileSystem = TSCBasic.localFileSystem) {
        self.fileSystem = fileSystem
    }

    func generate(for sdk: SDK, buildParameters: BuildParameters, destinationDir: AbsolutePath) throws -> AbsolutePath {
        // Generate the run destination parameters.
        let runDestination = XCBBuildParameters.RunDestination(
            platform: sdk.settingValue,
            sdk: sdk.settingValue,
            sdkVariant: nil,
            targetArchitecture: buildParameters.triple.arch.rawValue,
            supportedArchitectures: [],
            disableOnlyActiveArch: true
        )

        // Generate a table of any overriding build settings.
        var settings: [String: String] = [:]
        // An error with determining the override should not be fatal here.
        settings["CC"] = try? buildParameters.toolchain.getClangCompiler().pathString
        // Always specify the path of the effective Swift compiler, which was determined in the same way as for the native build system.
        settings["SWIFT_EXEC"] = buildParameters.toolchain.swiftCompilerPath.pathString
        settings["LIBRARY_SEARCH_PATHS"] = "$(inherited) \(try buildParameters.toolchain.toolchainLibDir.pathString)"
        settings["OTHER_CFLAGS"] = (
            ["$(inherited)"]
            + buildParameters.toolchain.extraFlags.cCompilerFlags
            + buildParameters.flags.cCompilerFlags.map { $0.spm_shellEscaped() }
        ).joined(separator: " ")
        settings["OTHER_CPLUSPLUSFLAGS"] = (
            ["$(inherited)"]
            + buildParameters.toolchain.extraFlags.cxxCompilerFlags
            + buildParameters.flags.cxxCompilerFlags.map { $0.spm_shellEscaped() }
        ).joined(separator: " ")
        settings["OTHER_SWIFT_FLAGS"] = (
            ["$(inherited)"]
            + buildParameters.toolchain.extraFlags.swiftCompilerFlags
            + buildParameters.flags.swiftCompilerFlags.map { $0.spm_shellEscaped() }
        ).joined(separator: " ")
        settings["OTHER_LDFLAGS"] = (
            ["$(inherited)"]
            + buildParameters.flags.linkerFlags.map { $0.spm_shellEscaped() }
        ).joined(separator: " ")

        settings["FRAMEWORK_SEARCH_PATHS"] = ["$(inherited)", "$(BUILT_PRODUCTS_DIR)/PackageFrameworks"].joined(separator: " ")
        print(try buildParameters.toolchain.toolchainLibDir.pathString)

        print(buildParameters.toolchain.extraFlags)

        // Optionally also set the list of architectures to build for.
        if let architectures = buildParameters.architectures, !architectures.isEmpty {
            settings["ARCHS"] = architectures.joined(separator: " ")
        }

        // Generate the build parameters.
        let params = XCBBuildParameters(
            configurationName: buildParameters.configuration.xcbuildName,
            overrides: .init(synthesized: .init(table: settings)),
            activeRunDestination: runDestination
        )

        // Write out the parameters as a JSON file, and return the path.
        let filePath = destinationDir.appending(component: "build-parameters-\(sdk.settingValue).json")
        let encoder = JSONEncoder.makeWithDefaults()
        let data = try encoder.encode(params)
        try self.fileSystem.writeFileContents(filePath, bytes: ByteString(data))
        return filePath
    }
}
