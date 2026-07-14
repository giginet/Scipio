import Foundation

struct PIFCompiler: Compiler {
    let descriptionPackage: DescriptionPackage
    private let buildOptions: BuildOptions
    /// Resolves whether a target keeps its public-header directory structure in the produced
    /// framework; the caller owns the per-target override rules.
    private let keepPublicHeadersStructure: @Sendable (_ targetName: String) -> Bool
    private let fileSystem: any FileSystem
    private let executor: any Executor
    private let buildOptionsMatrix: [String: BuildOptions]

    private let buildParametersGenerator: BuildParametersGenerator

    init(
        descriptionPackage: DescriptionPackage,
        buildOptions: BuildOptions,
        buildOptionsMatrix: [String: BuildOptions],
        keepPublicHeadersStructure: @escaping @Sendable (_ targetName: String) -> Bool,
        fileSystem: any FileSystem = LocalFileSystem.default,
        executor: any Executor = ProcessExecutor()
    ) {
        self.descriptionPackage = descriptionPackage
        self.buildOptions = buildOptions
        self.buildOptionsMatrix = buildOptionsMatrix
        self.keepPublicHeadersStructure = keepPublicHeadersStructure
        self.fileSystem = fileSystem
        self.executor = executor
        self.buildParametersGenerator = .init(buildOptions: buildOptions, fileSystem: fileSystem, executor: executor)
    }

    private func fetchDefaultToolchainBinPath() async throws -> URL {
        let result = try await executor.execute("/usr/bin/xcrun", "xcode-select", "-p")
        let rawString = try result.unwrapOutput().trimmingCharacters(in: .whitespacesAndNewlines)
        let developerDirPath = URL(filePath: rawString)
        return developerDirPath.appending(components: "Toolchains", "XcodeDefault.xctoolchain", "usr", "bin")
    }

    private func makeToolchain(for sdk: SDK) async throws -> UserToolchain {
        let toolchainDirPath = try await fetchDefaultToolchainBinPath()
        let toolchainGenerator = ToolchainGenerator(toolchainDirPath: toolchainDirPath)
        return try await toolchainGenerator.makeToolChain(sdk: sdk)
    }

    func createXCFramework(buildProduct: BuildProduct, outputDirectory: URL, overwrite: Bool) async throws {
        let sdks = buildOptions.sdks
        let sdkNames = sdks.map(\.displayName).joined(separator: ", ")
        let target = buildProduct.target

        // Build frameworks for each SDK
        logger.info("📦 Building \(target.name) for \(sdkNames)")

        // Scope the include rewrite to this target and its visible dependency closure so headers of
        // unrelated packages can never match (e.g. a generic `config.h`).
        let rewriterModules = try [buildProduct.target] + buildProduct.target.recursiveModuleDependencies()
        let headerIncludeRewriter = CHeaderIncludeRewriter(
            modules: rewriterModules,
            keepPublicHeadersStructure: { keepPublicHeadersStructure($0.name) }
        )

        let xcBuildClient: XCBuildClient = .init(
            buildProduct: buildProduct,
            buildOptions: buildOptions,
            configuration: buildOptions.buildConfiguration,
            packageLocator: descriptionPackage,
            headerIncludeRewriter: headerIncludeRewriter
        )

        let debugSymbolStripper = DWARFSymbolStripper(executor: executor)

        for sdk in sdks {
            let toolchain = try await makeToolchain(for: sdk)
            let buildParameters = await buildParametersGenerator.generate(from: buildOptions, toolchain: toolchain)

            let generator = try PIFGenerator(
                packageName: descriptionPackage.name,
                packageLocator: descriptionPackage,
                allModules: descriptionPackage.graph.allModules,
                toolchainLibDirectory: buildParameters.toolchain.toolchainLibDir,
                buildOptions: buildOptions,
                buildOptionsMatrix: buildOptionsMatrix
            )
            let pifPath = try await generator.generateJSON(for: sdk)
            let buildParametersPath = try buildParametersGenerator.generate(
                for: sdk,
                buildParameters: buildParameters,
                destinationDir: descriptionPackage.workspaceDirectory
            )

            do {
                let frameworkBundlePath = try await xcBuildClient.buildFramework(
                    sdk: sdk,
                    pifPath: pifPath,
                    buildParametersPath: buildParametersPath
                )

                if buildOptions.stripStaticDWARFSymbols && buildOptions.frameworkType == .static {
                    logger.debug("🐛 Stripping debug symbols of \(target.name) (\(sdk.displayName))")
                    let binaryPath = frameworkBundlePath.appending(component: buildProduct.target.c99name)
                    try await debugSymbolStripper.stripDebugSymbol(binaryPath)
                }
            } catch {
                logger.error("Unable to build for \(sdk.displayName)", metadata: .color(.red))
                logger.error(error)
            }
        }

        logger.info("🚀 Combining into XCFramework...")

        // If there is existing framework, remove it
        let frameworkName = target.xcFrameworkName
        let outputXCFrameworkPath = URL(filePath: outputDirectory.path).appending(component: frameworkName)
        if fileSystem.exists(outputXCFrameworkPath) && overwrite {
            logger.info("💥 Delete \(frameworkName)", metadata: .color(.red))
            try fileSystem.removeFileTree(outputXCFrameworkPath)
        }

        let debugSymbolPaths: [SDK: [URL]]?
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
}
