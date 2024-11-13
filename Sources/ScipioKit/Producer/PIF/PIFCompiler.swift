import Foundation
import PackageModel
import SPMBuildCore
import PackageGraph
import TSCBasic

struct PIFCompiler: Compiler {
    let descriptionPackage: DescriptionPackage
    private let buildOptions: BuildOptions
    private let fileSystem: any FileSystem
    private let executor: any Executor
    private let buildOptionsMatrix: [String: BuildOptions]
    private let toolchainEnvironment: ToolchainEnvironment?

    private let buildParametersGenerator: BuildParametersGenerator

    init(
        descriptionPackage: DescriptionPackage,
        buildOptions: BuildOptions,
        buildOptionsMatrix: [String: BuildOptions],
        toolchainEnvironment: ToolchainEnvironment? = nil,
        fileSystem: any FileSystem = TSCBasic.localFileSystem,
        executor: any Executor = ProcessExecutor()
    ) {
        self.descriptionPackage = descriptionPackage
        self.buildOptions = buildOptions
        self.buildOptionsMatrix = buildOptionsMatrix
        self.toolchainEnvironment = toolchainEnvironment
        self.fileSystem = fileSystem
        self.executor = executor
        self.buildParametersGenerator = .init(buildOptions: buildOptions, fileSystem: fileSystem)
    }

    private func fetchDefaultToolchainBinPath() async throws -> AbsolutePath {
        let result = try await executor.execute("/usr/bin/xcrun", "xcode-select", "-p")
        let rawString = try result.unwrapOutput().trimmingCharacters(in: .whitespacesAndNewlines)
        let developerDirPath = try AbsolutePath(validating: rawString)
        let toolchainPath = try RelativePath(validating: "./Toolchains/XcodeDefault.xctoolchain/usr/bin")
        return developerDirPath.appending(toolchainPath)
    }

    private func makeToolchain(for sdk: SDK) async throws -> UserToolchain {
        let toolchainDirPath = try await fetchDefaultToolchainBinPath()
        let toolchainGenerator = ToolchainGenerator(toolchainDirPath: toolchainDirPath, environment: toolchainEnvironment)
        return try await toolchainGenerator.makeToolChain(sdk: sdk)
    }

    func createXCFramework(buildProduct: BuildProduct, outputDirectory: URL, overwrite: Bool) async throws {
        let sdks = buildOptions.sdks
        let sdkNames = sdks.map(\.displayName).joined(separator: ", ")
        let target = buildProduct.target

        // Build frameworks for each SDK
        logger.info("📦 Building \(target.name) for \(sdkNames)")

        let xcBuildClient: XCBuildClient = .init(
            package: descriptionPackage,
            buildProduct: buildProduct,
            buildOptions: buildOptions,
            configuration: buildOptions.buildConfiguration
        )

        for sdk in sdks {
            let toolchain = try await makeToolchain(for: sdk)
            let buildParameters = try makeBuildParameters(toolchain: toolchain)

            let generator = try PIFGenerator(
                package: descriptionPackage,
                buildParameters: buildParameters,
                buildOptions: buildOptions,
                buildOptionsMatrix: buildOptionsMatrix
            )
            let pifPath = try generator.generateJSON(for: sdk)
            let buildParametersPath = try buildParametersGenerator.generate(
                for: sdk,
                buildParameters: buildParameters,
                destinationDir: descriptionPackage.workspaceDirectory
            )

            do {
                try await xcBuildClient.buildFramework(
                    sdk: sdk,
                    pifPath: pifPath,
                    buildParametersPath: buildParametersPath
                )
            } catch {
                logger.error("Unable to build for \(sdk.displayName)", metadata: .color(.red))
                logger.error(error)
            }
        }

        logger.info("🚀 Combining into XCFramework...")

        // If there is existing framework, remove it
        let frameworkName = target.xcFrameworkName
        let outputXCFrameworkPath = try AbsolutePath(validating: outputDirectory.path).appending(component: frameworkName)
        if fileSystem.exists(outputXCFrameworkPath) && overwrite {
            logger.info("💥 Delete \(frameworkName)", metadata: .color(.red))
            try fileSystem.removeFileTree(outputXCFrameworkPath)
        }

        let debugSymbolPaths: [SDK: [AbsolutePath]]?
        if buildOptions.isDebugSymbolsEmbedded {
            debugSymbolPaths = try await extractDebugSymbolPaths(target: target,
                                                                 buildConfiguration: buildOptions.buildConfiguration,
                                                                 sdks: Set(sdks))
        } else {
            debugSymbolPaths = nil
        }

        // Combine all frameworks into one XCFramework
        try await xcBuildClient.createXCFramework(
            sdks: Set(buildOptions.sdks),
            debugSymbols: debugSymbolPaths,
            outputPath: outputXCFrameworkPath
        )
    }

    private func makeBuildParameters(toolchain: UserToolchain) throws -> BuildParameters {
        #if compiler(>=6.0)
        try .init(
            destination: .target,
            dataPath: descriptionPackage.buildDirectory.spmAbsolutePath,
            configuration: buildOptions.buildConfiguration.spmConfiguration,
            toolchain: toolchain,
            flags: .init(),
            isXcodeBuildSystemEnabled: true,
            driverParameters: BuildParameters.Driver(enableParseableModuleInterfaces: buildOptions.enableLibraryEvolution)
        )
        #elseif swift(>=5.10)
        try .init(
            dataPath: descriptionPackage.buildDirectory.spmAbsolutePath,
            configuration: buildOptions.buildConfiguration.spmConfiguration,
            toolchain: toolchain,
            targetTriple: toolchain.targetTriple,
            flags: .init(),
            isXcodeBuildSystemEnabled: true,
            driverParameters: BuildParameters.Driver(enableParseableModuleInterfaces: buildOptions.enableLibraryEvolution)
        )
        #else
        try .init(
            dataPath: descriptionPackage.buildDirectory.spmAbsolutePath,
            configuration: buildOptions.buildConfiguration.spmConfiguration,
            toolchain: toolchain,
            destinationTriple: toolchain.triple,
            flags: .init(),
            enableParseableModuleInterfaces: buildOptions.enableLibraryEvolution,
            isXcodeBuildSystemEnabled: true
        )
        #endif
    }
}

extension BuildConfiguration {
    fileprivate var spmConfiguration: PackageModel.BuildConfiguration {
        switch self {
        case .debug: return .debug
        case .release: return .release
        }
    }
}
