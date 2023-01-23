import Foundation
import OrderedCollections
import TSCBasic

struct PIFFrameworkProducer {
    private let mode: Runner.Mode
    private let rootPackage: Package
    private let buildOptions: BuildOptions
    private let cacheMode: Runner.Options.CacheMode
    private let platformMatrix: PlatformMatrix
    private let overwrite: Bool
    private let outputDir: URL
    private let fileSystem: any FileSystem

    private var cacheStorage: (any CacheStorage)? {
        switch cacheMode {
        case .disabled, .project: return nil
        case .storage(let storage): return storage
        }
    }

    private var isCacheEnabled: Bool {
        switch cacheMode {
        case .disabled: return false
        case .project, .storage: return true
        }
    }

    init(
        mode: Runner.Mode,
        rootPackage: Package,
        buildOptions: BuildOptions,
        cacheMode: Runner.Options.CacheMode,
        platformMatrix: PlatformMatrix,
        overwrite: Bool,
        outputDir: URL,
        fileSystem: any FileSystem = localFileSystem
    ) {
        self.mode = mode
        self.rootPackage = rootPackage
        self.buildOptions = buildOptions
        self.cacheMode = cacheMode
        self.platformMatrix = platformMatrix
        self.overwrite = overwrite
        self.outputDir = outputDir
        self.fileSystem = fileSystem
    }

    func produce() async throws {
        for sdk in sdksToBuild {
        }
    }

    private var sdksToBuild: Set<SDK> {
        if buildOptions.isSimulatorSupported {
            return buildOptions.sdks.reduce([]) { (sdks: Set<SDK>, sdk) in sdks.union(sdk.extractForSimulators()) }
        } else {
            return Set(buildOptions.sdks)
        }
    }
}

private struct PIFGenerator {
    func generate() throws -> AbsolutePath {
        return try .init(validating: "$HOME")
    }
}

private struct XCBuildRunner {
    private let executor: any Executor

    fileprivate init(executor: any Executor) {
        self.executor = executor
    }

    fileprivate enum Target {
        case allIncludingTests
        case allExcludingTests
        case target(String)
        case product(String)

        var argumentValue: String {
            switch self {
            case .allExcludingTests: return "AllExcludingTests"
            case .allIncludingTests: return "AllIncludingTests"
            case .target(let targetName): return targetName
            case .product(let productName):
                return "\(productName)_\(String(productName.hash, radix: 16, uppercase: true))_PackageProduct"
            }
        }
    }

    private func fetchXCBuildPath() async throws -> AbsolutePath {
        let developerDirPath = try await fetchDeveloperDirPath()
        let relativePath = try RelativePath(validating: "../SharedFrameworks/XCBuild.framework/Versions/A/Support/xcbuild")
        return developerDirPath.appending(relativePath)
    }

    private func fetchDeveloperDirPath() async throws -> AbsolutePath {
        let result = try await executor.execute(
            "/usr/bin/xcrun",
            "xcode-select",
            "-p"
        )
        return try AbsolutePath(validating: try result.unwrapOutput())
    }

    fileprivate func execute(
        pifPath: AbsolutePath,
        buildParametersPath: AbsolutePath,
        configuration: BuildConfiguration,
        target: Target
    ) async throws {
        let xcbuildPath = try await fetchXCBuildPath()
        try await executor.execute(
            xcbuildPath.pathString,
            "build",
            pifPath.pathString,
            "--configuration",
            configuration.settingsValue,
            "--derivedDataPath",
            "",
            "--buildParametersFile",
            buildParametersPath.pathString,
            "--target",
            target.argumentValue
        )
    }
}

