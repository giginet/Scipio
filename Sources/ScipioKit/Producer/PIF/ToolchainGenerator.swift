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
        #if compiler(>=6.0)
        return try UserToolchain(
            swiftSDK: destination,
            environment: environment.asSwiftPMEnvironment
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
        let macosSDKPlatformPaths = try await nonCachingSDKPlatformFrameworkPaths()
        extraCCFlags += ["-F", macosSDKPlatformPaths.fwk.pathString]
        extraSwiftCFlags += ["-F", macosSDKPlatformPaths.fwk.pathString]
        extraSwiftCFlags += ["-I", macosSDKPlatformPaths.lib.pathString]
        extraSwiftCFlags += ["-L", macosSDKPlatformPaths.lib.pathString]

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

fileprivate extension ToolchainGenerator {

    /// A non-caching environment-aware implementation of `SwiftSDK.sdkPlatformFrameworkPaths`
    /// Returns `macosx` sdk platform framework path.
    func nonCachingSDKPlatformFrameworkPaths() async throws -> (fwk: AbsolutePath, lib: AbsolutePath) {
        let platformPath = try await executor.execute(
            "/usr/bin/xcrun",
            "--sdk",
            "macosx",
            "--show-sdk-platform-path"
        )
        .unwrapOutput()
        .spm_chomp()

        guard !platformPath.isEmpty else {
            throw StringError("could not determine SDK platform path")
        }

        // For XCTest framework.
        let fwk = try AbsolutePath(validating: platformPath).appending(
            components: "Developer", "Library", "Frameworks"
        )

        // For XCTest Swift library.
        let lib = try AbsolutePath(validating: platformPath).appending(
            components: "Developer", "usr", "lib"
        )

        return (fwk, lib)
    }

}
