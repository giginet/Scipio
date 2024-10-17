import Foundation
import TSCUtility
@_spi(SwiftPMInternal) import PackageModel
@_spi(SwiftPMInternal) import struct Basics.Environment
import TSCBasic
import struct Basics.Triple

struct ToolchainGenerator {
    private let toolchainDirPath: AbsolutePath
    private let environment: [String: String]?
    private let executor: any Executor

    init(
        toolchainDirPath: AbsolutePath,
        environment: [String: String]? = nil,
        executor: any Executor = ProcessExecutor()
    ) {
        self.toolchainDirPath = toolchainDirPath
        self.environment = environment
        self.executor = executor
    }

    func makeToolChain(sdk: SDK) async throws -> UserToolchain {
        let destination: SwiftSDK = try await makeDestination(sdk: sdk)
        return try UserToolchain(
            swiftSDK: destination,
            environment: environment.map(Environment.init) ?? .current
        )
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
        return SwiftSDK(
            hostTriple: try? Triple("arm64-apple-\(sdk.settingValue)"),
            targetTriple: try? Triple("arm64-apple-\(sdk.settingValue)"),
            toolset: .init(toolchainBinDir: toolchainDirPath.spmAbsolutePath, buildFlags: buildFlags),
            pathsConfiguration: .init(sdkRootPath: sdkPath.spmAbsolutePath),
            xctestSupport: .supported
        )
    }
}
