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
            environment: environment.asSwiftPMEnvironment
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
        let macosSDKPlatformPaths = try await resolveSDKPlatformFrameworkPaths()
        extraCCFlags += ["-F", macosSDKPlatformPaths.frameworkPath.pathString]
        extraSwiftCFlags += ["-F", macosSDKPlatformPaths.frameworkPath.pathString]
        extraSwiftCFlags += ["-I", macosSDKPlatformPaths.frameworkPath.pathString]
        extraSwiftCFlags += ["-L", macosSDKPlatformPaths.frameworkPath.pathString]

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

extension ToolchainGenerator {

    /// A non-caching environment-aware implementation of `SwiftSDK.sdkPlatformFrameworkPaths`
    /// This implementation is based on the original SwiftPM
    /// https://github.com/swiftlang/swift-package-manager/blob/release/6.0/Sources/PackageModel/SwiftSDKs/SwiftSDK.swift#L592-L595
    /// Returns `macosx` sdk platform framework path.
    fileprivate func resolveSDKPlatformFrameworkPaths() async throws -> (frameworkPath: AbsolutePath, libPath: AbsolutePath) {
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
        let frameworkPath = try AbsolutePath(validating: platformPath).appending(
            components: "Developer", "Library", "Frameworks"
        )

        // For XCTest Swift library.
        let libPath = try AbsolutePath(validating: platformPath).appending(
            components: "Developer", "usr", "lib"
        )

        return (frameworkPath, libPath)
    }

}
