import Foundation
import TSCUtility
import PackageModel
import TSCBasic

struct ToolchainGenerator {
    private let toolchainDirPath: AbsolutePath
    private let executor: any Executor

    init(toolchainDirPath: AbsolutePath, executor: any Executor = ProcessExecutor()) {
        self.toolchainDirPath = toolchainDirPath
        self.executor = executor
    }

    func makeToolChain(sdk: SDK) async throws -> UserToolchain {
        let destination: Destination = try await makeDestination(sdk: sdk)
        return try UserToolchain(destination: destination)
    }

    private func makeDestination(
        sdk: SDK
    ) async throws -> Destination {
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
        let sdkPaths = try Destination.sdkPlatformFrameworkPaths(environment: [:])
        extraCCFlags += ["-F", sdkPaths.fwk.pathString]
        extraSwiftCFlags += ["-F", sdkPaths.fwk.pathString]
        extraSwiftCFlags += ["-I", sdkPaths.lib.pathString]
        extraSwiftCFlags += ["-L", sdkPaths.lib.pathString]

        let destination = Destination(
//            hostTriple: try? Triple("arm64-apple-\(sdk.settingValue)"),
//            targetTriple: try? Triple("arm64-apple-\(sdk.settingValue)"),
            sdkRootDir: sdkPath,
            toolchainBinDir: toolchainDirPath,
            extraFlags: BuildFlags(cCompilerFlags: extraCCFlags, swiftCompilerFlags: extraSwiftCFlags)
        )
        return destination
    }
}
