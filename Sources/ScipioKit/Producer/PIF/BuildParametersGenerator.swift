import Foundation
import TSCBasic
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
    private let executor: any Executor
    private let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting.formUnion([.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        return encoder
    }()

    init(buildOptions: BuildOptions, fileSystem: any FileSystem = localFileSystem, executor: some Executor) {
        self.buildOptions = buildOptions
        self.fileSystem = fileSystem
        self.executor = executor
    }

    func generate(for sdk: SDK, buildParameters: Parameters, destinationDir: AbsolutePath) throws -> AbsolutePath {
        let targetArchitecture = buildParameters.arch

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
        settings["CC"] = buildParameters.toolchain.clangCompilerPath.path(percentEncoded: false)
        // Always specify the path of the effective Swift compiler, which was determined in the same way as for the native build system.
        settings["SWIFT_EXEC"] = buildParameters.toolchain.swiftCompilerPath.path(percentEncoded: false)
        settings["LIBRARY_SEARCH_PATHS"] = expandFlags(
            buildParameters.toolchain.toolchainLibDir.path(percentEncoded: false)
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
            configurationName: buildParameters.configuration.settingsValue,
            overrides: .init(synthesized: .init(table: settings)),
            activeRunDestination: runDestination
        )

        // Write out the parameters as a JSON file, and return the path.
        let filePath = destinationDir.appending(component: "build-parameters-\(sdk.settingValue).json")

        let data = try jsonEncoder.encode(params)

        try self.fileSystem.writeFileContents(filePath, bytes: ByteString(data))
        return filePath
    }

    func generate(from buildOptions: BuildOptions, toolchain: UserToolchain) async -> Parameters {
        let arch = try? await executor.execute([
            "/usr/bin/xcrun",
            "arch",
        ]).unwrapOutput()

        return Parameters(
            toolchain: toolchain,
            configuration: buildOptions.buildConfiguration,
            arch: arch ?? "arm64",
            // ref: https://github.com/swiftlang/swift-package-manager/blob/main/Sources/SPMBuildCore/BuildParameters/BuildParameters.swift#L194
            flags: Parameters.Flags(
                cCompilerFlags: ["-g"],
                cxxCompilerFlags: ["-g"],
                swiftCompilerFlags: ["-g"],
                linkerFlags: []
            )
        )
    }

    private func expandFlags(_ extraFlags: [String]?...) -> String {
        (["$(inherited)"] + extraFlags.compactMap { $0 }.flatMap { $0 })
            .joined(separator: " ")
    }

    private func expandFlags(_ extraFlag: String) -> String {
        expandFlags([extraFlag])
    }

    struct Parameters {
        var toolchain: UserToolchain
        var configuration: BuildConfiguration
        var arch: String
        let flags: Flags

        struct Flags {
            var cCompilerFlags: [String]
            var cxxCompilerFlags: [String]
            var swiftCompilerFlags: [String]
            var linkerFlags: [String]
        }
    }
}
