import Foundation
import TSCBasic

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
        extraSwiftCFlags += ["-I", macosSDKPlatformPaths.libPath.pathString]
        extraSwiftCFlags += ["-L", macosSDKPlatformPaths.libPath.pathString]

        let clangCompilerPath = try await resolveClangCompilerPath()
        let swiftCompilerPath = try await resolveSwiftCompilerPath()
        let toolchainLibDir = swiftCompilerPath.resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appending(components: "..", "..", "lib")

       return UserToolchain(
            clangCompilerPath: clangCompilerPath,
            swiftCompilerPath: swiftCompilerPath,
            toolchainLibDir: toolchainLibDir,
            sdkPath: sdkPath.asURL,
            extraFlags: UserToolchain.ExtraFlags(
                cCompilerFlags: extraCCFlags,
                cxxCompilerFlags: [],
                swiftCompilerFlags: extraSwiftCFlags
            )
        )
    }

    private func resolveClangCompilerPath() async throws -> URL {
        let clangCompilerPath = try await executor.execute(
            "/usr/bin/xcrun",
            "--find",
            "clang"
        )
        .unwrapOutput()
        .spm_chomp()

        return URL(filePath: clangCompilerPath)
    }

    private func resolveSwiftCompilerPath() async throws -> URL {
        let clangCompilerPath = try await executor.execute(
            "/usr/bin/xcrun",
            "--find",
            "swiftc"
        )
        .unwrapOutput()
        .spm_chomp()

        return URL(filePath: clangCompilerPath)
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

struct UserToolchain {
    let clangCompilerPath: URL
    let swiftCompilerPath: URL
    let toolchainLibDir: URL
    let sdkPath: URL
    let extraFlags: ExtraFlags

    struct ExtraFlags {
        let cCompilerFlags: [String]
        let cxxCompilerFlags: [String]
        let swiftCompilerFlags: [String]
    }
}
