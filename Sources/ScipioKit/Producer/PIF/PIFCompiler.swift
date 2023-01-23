import Foundation
import PackageModel
import SPMBuildCore
import PackageGraph
import OrderedCollections
import TSCBasic

struct PIFCompiler: Compiler {
    let rootPackage: Package
    private let buildOptions: BuildOptions
    private let fileSystem: any TSCBasic.FileSystem

    private let toolchainGenerator: ToolchainGenerator
    private let buildParametersGenerator: BuildParametersGenerator

    init(
        rootPackage: Package,
        buildOptions: BuildOptions,
        fileSystem: any TSCBasic.FileSystem = TSCBasic.localFileSystem
    ) {
        self.rootPackage = rootPackage
        self.buildOptions = buildOptions
        self.fileSystem = fileSystem

        let toolchainDirPath = try! AbsolutePath(validating: "/usr/bin") // TODO ./Toolchains/XcodeDefault.xctoolchain/usr/bin
        self.toolchainGenerator = ToolchainGenerator(toolchainDirPath: toolchainDirPath)
        self.buildParametersGenerator = .init(fileSystem: fileSystem)
    }

    func createXCFramework(target: ResolvedTarget, outputDirectory: URL, overwrite: Bool) async throws {
        let sdks = sdksToBuild
        let sdkNames = sdks.map(\.displayName).joined(separator: ", ")
        logger.info("📦 Building \(target.name) for \(sdkNames)")

        let xcBuildClient: XCBuildClient = .init(
            package: rootPackage,
            productName: target.name,
            configuration: buildOptions.buildConfiguration
        )

        for sdk in sdks {
            let toolchain = try await toolchainGenerator.makeToolChain(sdk: sdk)
            let buildParameters = try makeBuildParameters(toolchain: toolchain)

            let generator = try PIFGenerator(
                package: rootPackage,
                buildParameters: buildParameters,
                buildOptions: buildOptions
            )
            let pifPath = try generator.generateJSON(for: sdk)
            let buildParametersPath = try buildParametersGenerator.generate(
                for: sdk,
                buildParameters: buildParameters,
                destinationDir: try AbsolutePath(validating: rootPackage.buildDirectory.path)
            )

            do {
                try await xcBuildClient.buildFramework(
                    pifPath: pifPath,
                    buildParametersPath: buildParametersPath
                )
            } catch {
                logger.error("Unable to build for \(sdk.displayName)", metadata: .color(.red))
                logger.error(error)
            }
        }

        logger.info("🚀 Combining into XCFramework...")

        let debugSymbolPaths: [URL]?
        if buildOptions.isDebugSymbolsEmbedded {
            debugSymbolPaths = try await extractDebugSymbolPaths(target: target,
                                                                 buildConfiguration: buildOptions.buildConfiguration,
                                                                 sdks: sdks)
        } else {
            debugSymbolPaths = nil
        }

        let frameworkName = target.xcFrameworkName
        let outputXCFrameworkPath = try AbsolutePath(validating: outputDirectory.path).appending(component: frameworkName)
        if fileSystem.exists(outputXCFrameworkPath) && overwrite {
            logger.info("💥 Delete \(frameworkName)", metadata: .color(.red))
            try fileSystem.removeFileTree(outputXCFrameworkPath)
        }

        try await xcBuildClient.createXCFramework(
            sdks: sdksToBuild,
            debugSymbols: debugSymbolPaths,
            outputPath: outputXCFrameworkPath
        )
    }

    private func makeBuildParameters(toolchain: UserToolchain) throws -> BuildParameters {
        .init(
            dataPath: try AbsolutePath(validating: rootPackage.buildDirectory.path),
            configuration: buildOptions.buildConfiguration.spmConfiguration,
            toolchain: toolchain,
            destinationTriple: toolchain.triple,
            flags: .init(),
            isXcodeBuildSystemEnabled: true
        )
    }

    private var sdksToBuild: Set<SDK> {
        if buildOptions.isSimulatorSupported {
            return buildOptions.sdks.reduce([]) { (sdks: Set<SDK>, sdk) in sdks.union(sdk.extractForSimulators()) }
        } else {
            return Set(buildOptions.sdks)
        }
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
