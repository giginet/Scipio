import Foundation

struct ToolchainGenerator {
    private let toolchainDirPath: URL
    private let environment: [String: String]?
    private let executor: any Executor

    init(
        toolchainDirPath: URL,
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
        let sdkPath = URL(filePath: sdkPathString)

        // Compute common arguments for clang and swift.
        var extraCCFlags: [String] = []
        var extraSwiftCFlags: [String] = []
        let macosSDKPlatformPaths = try await resolveSDKPlatformFrameworkPaths()
        extraCCFlags += ["-F", macosSDKPlatformPaths.frameworkPath.path(percentEncoded: false)]
        extraSwiftCFlags += ["-F", macosSDKPlatformPaths.frameworkPath.path(percentEncoded: false)]
        extraSwiftCFlags += ["-I", macosSDKPlatformPaths.libPath.path(percentEncoded: false)]
        extraSwiftCFlags += ["-L", macosSDKPlatformPaths.libPath.path(percentEncoded: false)]

        let clangCompilerPath = try await resolveClangCompilerPath()
        let swiftCompilerPath = try await resolveSwiftCompilerPath()
        let toolchainLibDir = swiftCompilerPath.resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appending(components: "..", "..", "lib")

       return UserToolchain(
            clangCompilerPath: clangCompilerPath,
            swiftCompilerPath: swiftCompilerPath,
            toolchainLibDir: toolchainLibDir,
            sdkPath: sdkPath,
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
    fileprivate func resolveSDKPlatformFrameworkPaths() async throws -> (frameworkPath: URL, libPath: URL) {
        let platformPath = try await executor.execute(
            "/usr/bin/xcrun",
            "--sdk",
            "macosx",
            "--show-sdk-platform-path"
        )
        .unwrapOutput()
        .spm_chomp()

        guard !platformPath.isEmpty else {
            throw Error.couldNotDetermineSDKPlatformPath
        }

        // For XCTest framework.
        let frameworkPath = URL(filePath: platformPath).appending(
            components: "Developer", "Library", "Frameworks"
        )

        // For XCTest Swift library.
        let libPath = URL(filePath: platformPath).appending(
            components: "Developer", "usr", "lib"
        )

        return (frameworkPath, libPath)
    }

    enum Error: LocalizedError {
        case couldNotDetermineSDKPlatformPath

        var errorDescription: String? {
            switch self {
            case .couldNotDetermineSDKPlatformPath:
                return "Could not determine SDK platform path"
            }
        }
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
