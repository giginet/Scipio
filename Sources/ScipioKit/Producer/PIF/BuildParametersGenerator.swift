import Foundation
import TSCBasic
import XCBuildSupport
import SPMBuildCore

struct XCBBuildParameters: Encodable, Sendable {
    struct RunDestination: Encodable, Sendable {
        var platform: String
        var sdk: String
        var sdkVariant: String?
        var targetArchitecture: String
        var supportedArchitectures: [String]
        var disableOnlyActiveArch: Bool
    }

    struct XCBSettingsTable: Encodable, Sendable {
        var table: [String: String]
    }

    struct SettingsOverride: Encodable, Sendable {
        var synthesized: XCBSettingsTable?
    }

    var configurationName: String
    var overrides: SettingsOverride
    var activeRunDestination: RunDestination
}

struct BuildParametersGenerator {
    private let buildOptions: BuildOptions
    private let fileSystem: any FileSystem

    init(buildOptions: BuildOptions, fileSystem: any FileSystem = TSCBasic.localFileSystem) {
        self.buildOptions = buildOptions
        self.fileSystem = fileSystem
    }

    func generate(for sdk: SDK, buildParameters: BuildParameters, destinationDir: AbsolutePath) throws -> AbsolutePath {
        #if swift(>=5.10)
        let targetArchitecture = buildParameters.targetTriple.arch?.rawValue ?? "arm64"
        #elseif swift(>=5.9)
        let targetArchitecture = buildParameters.triple.arch?.rawValue ?? "arm64"
        #endif

        // Generate the run destination parameters.
        let runDestination = XCBBuildParameters.RunDestination(
            platform: sdk.settingValue,
            sdk: sdk.settingValue,
            sdkVariant: nil,
            targetArchitecture: targetArchitecture,
            supportedArchitectures: [],
            disableOnlyActiveArch: true
        )

        // Generate a table of any overriding build settings.
        var settings: [String: String] = [:]
        // An error with determining the override should not be fatal here.
        settings["CC"] = try? buildParameters.toolchain.getClangCompiler().pathString
        // Always specify the path of the effective Swift compiler, which was determined in the same way as for the native build system.
        settings["SWIFT_EXEC"] = buildParameters.toolchain.swiftCompilerPath.pathString
        settings["LIBRARY_SEARCH_PATHS"] = expandFlags(
            try buildParameters.toolchain.toolchainLibDir.pathString
        )
        settings["OTHER_CFLAGS"] = expandFlags(
            buildParameters.toolchain.extraFlags.cCompilerFlags,
            buildParameters.flags.cCompilerFlags.map { $0.spm_shellEscaped() }
        )
        settings["OTHER_CPLUSPLUSFLAGS"] = expandFlags(
            buildParameters.toolchain.extraFlags.cxxCompilerFlags,
            buildParameters.flags.cxxCompilerFlags.map { $0.spm_shellEscaped() }
        )
        settings["OTHER_SWIFT_FLAGS"] = expandFlags(
            buildParameters.toolchain.extraFlags.swiftCompilerFlags,
            buildParameters.flags.swiftCompilerFlags.map { $0.spm_shellEscaped() }
        )
        settings["OTHER_LDFLAGS"] = expandFlags(
            buildParameters.flags.linkerFlags.map { $0.spm_shellEscaped() }
        )

        let additionalSettings = buildOptions.extraBuildParameters ?? [:]
        settings.merge(additionalSettings, uniquingKeysWith: { $1 })

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

    private func expandFlags(_ extraFlags: [String]?...) -> String {
        (["$(inherited)"] + extraFlags.compactMap { $0 }.flatMap { $0 })
            .joined(separator: " ")
    }

    private func expandFlags(_ extraFlag: String) -> String {
        expandFlags([extraFlag])
    }
}
