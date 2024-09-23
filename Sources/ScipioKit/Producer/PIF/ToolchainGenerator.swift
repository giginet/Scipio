import Foundation
import TSCUtility
#if compiler(>=6.0)
@_spi(SwiftPMInternal) import PackageModel
@_spi(SwiftPMInternal) import struct Basics.Environment
#else
import PackageModel
#endif
import TSCBasic
import struct Basics.Triple

struct ToolchainGenerator {
    private let toolchainDirPath: AbsolutePath
    private let executor: any Executor
    private let environment: [String: String]?

    init(
        toolchainDirPath: AbsolutePath,
        executor: any Executor = ProcessExecutor(),
        environment: [String: String]? = nil
    ) {
        self.toolchainDirPath = toolchainDirPath
        self.executor = executor
        self.environment = environment
    }

    func makeToolChain(sdk: SDK) async throws -> UserToolchain {
        let destination: SwiftSDK = try await makeDestination(sdk: sdk)
        #if compiler(>=6.0)
        return try UserToolchain(
            swiftSDK: destination,
            environment: environment.map(Environment.init) ?? .current
        )
        #elseif swift(>=5.10)
        return try UserToolchain(swiftSDK: destination)
        #else
        return try UserToolchain(destination: destination)
        #endif
    }

    private func makeDestination(
        sdk: SDK
    ) async throws -> SwiftSDK {
        let sdkPathString = try await executor.execute(
            "/usr/bin/xcrun",
            "--sdk",
            sdk.settingValue,
            "--show-sdk-path"
        )
            .unwrapOutput()
            .spm_chomp()
        let sdkPath = try AbsolutePath(validating: sdkPathString)

        // Compute common arguments for clang and swift.
        var extraCCFlags: [String] = []
        var extraSwiftCFlags: [String] = []
        let sdkPaths = try SwiftSDK.sdkPlatformFrameworkPaths(environment: [:])
        extraCCFlags += ["-F", sdkPaths.fwk.pathString]
        extraSwiftCFlags += ["-F", sdkPaths.fwk.pathString]
        extraSwiftCFlags += ["-I", sdkPaths.lib.pathString]
        extraSwiftCFlags += ["-L", sdkPaths.lib.pathString]

        let buildFlags = BuildFlags(cCompilerFlags: extraCCFlags, swiftCompilerFlags: extraSwiftCFlags)
        #if compiler(>=6.0)
        return SwiftSDK(
            hostTriple: try? Triple("arm64-apple-\(sdk.settingValue)"),
            targetTriple: try? Triple("arm64-apple-\(sdk.settingValue)"),
            toolset: .init(toolchainBinDir: toolchainDirPath.spmAbsolutePath, buildFlags: buildFlags),
            pathsConfiguration: .init(sdkRootPath: sdkPath.spmAbsolutePath),
            xctestSupport: .supported
        )
        #elseif swift(>=5.10)
        return SwiftSDK(
            hostTriple: try? Triple("arm64-apple-\(sdk.settingValue)"),
            targetTriple: try? Triple("arm64-apple-\(sdk.settingValue)"),
            toolset: .init(toolchainBinDir: toolchainDirPath.spmAbsolutePath, buildFlags: buildFlags),
            pathsConfiguration: .init(sdkRootPath: sdkPath.spmAbsolutePath)
        )
        #else
        return Destination(
            hostTriple: try? Triple("arm64-apple-\(sdk.settingValue)"),
            targetTriple: try? Triple("arm64-apple-\(sdk.settingValue)"),
            sdkRootDir: sdkPath.spmAbsolutePath,
            toolchainBinDir: toolchainDirPath.spmAbsolutePath,
            extraFlags: buildFlags
        )
        #endif
    }
}
