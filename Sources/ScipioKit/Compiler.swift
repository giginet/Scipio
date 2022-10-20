import Foundation
import PackageGraph
import TSCBasic

struct Compiler<E: Executor> {
    let rootPackage: Package
    let executor: E
    let cacheStorage: (any CacheStorage)?
    let fileSystem: any FileSystem
    private let extractor: DwarfExtractor<E>

    enum BuildMode {
        case createPackage
        case prepareDependencies
    }

    init(rootPackage: Package, cacheStorage: (any CacheStorage)?, executor: E = ProcessExecutor(), fileSystem: any FileSystem = localFileSystem) {
        self.rootPackage = rootPackage
        self.executor = executor
        self.cacheStorage = cacheStorage
        self.fileSystem = fileSystem
        self.extractor = DwarfExtractor(executor: executor)
    }

    private func buildArtifactsDirectoryPath(buildConfiguration: BuildConfiguration, sdk: SDK) -> AbsolutePath {
        rootPackage.workspaceDirectory.appending(component: "\(buildConfiguration.settingsValue)-\(sdk.name)")
    }

    private func buildDebugSymbolPath(buildConfiguration: BuildConfiguration, sdk: SDK, target: ResolvedTarget) -> AbsolutePath {
        buildArtifactsDirectoryPath(buildConfiguration: buildConfiguration, sdk: sdk).appending(component: "\(target).framework.dSYM")
    }

    func build(mode: BuildMode, buildOptions: BuildOptions, outputDir: AbsolutePath, isCacheEnabled: Bool) async throws {
        let cacheSystem = CacheSystem(rootPackage: rootPackage,
                                      buildOptions: buildOptions,
                                      outputDirectory: outputDir,
                                      storage: cacheStorage)

        logger.info("🗑️ Cleaning \(rootPackage.name)...")
        try await execute(CleanCommand(
            projectPath: rootPackage.projectPath,
            buildDirectory: rootPackage.workspaceDirectory
        ))

        let buildConfiguration: BuildConfiguration = buildOptions.buildConfiguration
        let sdks: [SDK]
        if buildOptions.isSimulatorSupported {
            sdks = buildOptions.sdks.flatMap { $0.extractForSimulators() }
        } else {
            sdks = buildOptions.sdks
        }

        let packages: [ResolvedPackage]
        switch mode {
        case .createPackage:
            packages = rootPackage.graph.rootPackages
        case .prepareDependencies:
            packages = dependenciesPackages(for: rootPackage)
        }
        for subPackage in packages {
            for target in subPackage.targets where target.type == .library {
                let frameworkName = frameworkName(for: target)
                let xcframeworkPath = outputDir.appending(component: frameworkName)
                let exists = fileSystem.exists(xcframeworkPath)

                if exists {
                    if isCacheEnabled {
                        let isValidCache = await cacheSystem.existsValidCache(subPackage: subPackage, target: target)
                        if isValidCache {
                            logger.info("✅ Valid \(target.name).xcframework is exists. Skip building.", metadata: .color(.green))
                            continue
                        } else {
                            logger.warning("⚠️ Existing \(frameworkName) is outdated.", metadata: .color(.yellow))
                            logger.info("💥 Delete \(frameworkName)", metadata: .color(.red))
                            try fileSystem.removeFileTree(xcframeworkPath)
                        }
                    }
                    try fileSystem.removeFileTree(xcframeworkPath)
                }

                let frameworkPath = outputDir.appending(component: frameworkName)
                if await cacheSystem.restoreCacheIfPossible(subPackage: subPackage, target: target) {
                    logger.info("✅ Restore \(frameworkName) from cache storage", metadata: .color(.green))
                } else {
                    try await createXCFramework(target: target,
                                                buildConfiguration: buildConfiguration,
                                                isDebugSymbolsEmbedded: buildOptions.isDebugSymbolsEmbedded,
                                                sdks: Set(sdks),
                                                outputDirectory: outputDir)
                }

                try? await cacheSystem.cacheFramework(frameworkPath, subPackage: subPackage, target: target)

                if case .prepareDependencies = mode {
                    do {
                        try await cacheSystem.generateVersionFile(subPackage: subPackage, target: target)
                    } catch {
                        logger.warning("⚠️ Could not create VersionFile. This framework will not be cached.", metadata: .color(.yellow))
                    }
                }
            }
        }
    }

    private func frameworkName(for target: ResolvedTarget) -> String {
        "\(target.name.packageNamed()).xcframework"
    }

    private func createXCFramework(target: ResolvedTarget,
                                   buildConfiguration: BuildConfiguration,
                                   isDebugSymbolsEmbedded: Bool,
                                   sdks: Set<SDK>,
                                   outputDirectory: AbsolutePath) async throws {
        let sdkNames = sdks.map(\.displayName).joined(separator: ", ")
        logger.info("📦 Building \(target.name) for \(sdkNames)")

        for sdk in sdks {
            try await execute(ArchiveCommand(context: .init(package: rootPackage, target: target, buildConfiguration: buildConfiguration, sdk: sdk)))
        }

        logger.info("🚀 Combining into XCFramework...")

        let debugSymbolPaths: [AbsolutePath]?
        if isDebugSymbolsEmbedded {
            debugSymbolPaths = try await extractDebugSymbolPaths(target: target,
                                                                 buildConfiguration: buildConfiguration,
                                                                 sdks: sdks)
        } else {
            debugSymbolPaths = nil
        }

        try await execute(CreateXCFrameworkCommand(
            context: .init(package: rootPackage,
                           target: target,
                           buildConfiguration: buildConfiguration,
                           sdks: sdks,
                           debugSymbolPaths: debugSymbolPaths),
            outputDir: outputDirectory
        ))
    }

    private func extractDebugSymbolPaths(target: ResolvedTarget, buildConfiguration: BuildConfiguration, sdks: Set<SDK>) async throws -> [AbsolutePath] {
        let debugSymbols: [DebugSymbol] = sdks.compactMap { sdk in
            let dsymPath = buildDebugSymbolPath(buildConfiguration: buildConfiguration, sdk: sdk, target: target)
            guard fileSystem.exists(dsymPath) else { return nil }
            return DebugSymbol(dSYMPath: dsymPath,
                               target: target,
                               sdk: sdk,
                               buildConfiguration: buildConfiguration)
        }
        // You can use AsyncStream
        var symbolMapPaths: [AbsolutePath] = []
        for dSYMs in debugSymbols {
            let maps = try await self.extractor.dump(dwarfPath: dSYMs.dwarfPath)
            let paths = maps.values.map { uuid in
                buildArtifactsDirectoryPath(buildConfiguration: dSYMs.buildConfiguration, sdk: dSYMs.sdk)
                    .appending(component: "\(uuid.uuidString).bcsymbolmap")
            }
            symbolMapPaths.append(contentsOf: paths)
        }
        return debugSymbols.map { $0.dSYMPath } + symbolMapPaths
    }

    @discardableResult
    private func execute<Command: XcodeBuildCommand>(_ command: Command) async throws -> ExecutorResult {
        try await executor.execute(command.buildArguments())
    }

    private func dependenciesPackages(for package: Package) -> [ResolvedPackage] {
        package.graph.packages
            .filter { $0.manifest.displayName != package.manifest.displayName }
    }

    private struct CleanCommand: XcodeBuildCommand {
        let projectPath: AbsolutePath
        let buildDirectory: AbsolutePath

        let subCommand: String = "clean"
        var options: [XcodeBuildOption] {
            [.init(key: "project", value: projectPath.pathString)]
        }

        var environmentVariables: [XcodeBuildEnvironmentVariable] {
            [.init(key: "BUILD_DIR", value: buildDirectory.pathString)]
        }
    }

    fileprivate struct ArchiveCommand: XcodeBuildCommand {
        struct Context: XcodeBuildContext {
            var package: Package
            var target: ResolvedTarget
            var buildConfiguration: BuildConfiguration
            var sdk: SDK
        }
        var context: Context
        var xcArchivePath: AbsolutePath {
            context.xcArchivePath
        }

        let subCommand: String = "archive"
        var options: [XcodeBuildOption] {
            [
                ("project", context.projectPath.pathString),
                ("configuration", context.buildConfiguration.settingsValue),
                ("scheme", context.target.name),
                ("archivePath", xcArchivePath.pathString),
                ("destination", context.sdk.destination),
            ].map(XcodeBuildOption.init(key:value:))
        }

        var environmentVariables: [XcodeBuildEnvironmentVariable] {
            [
                ("BUILD_DIR", context.package.workspaceDirectory.pathString),
                ("SKIP_INSTALL", "NO"),
            ].map(XcodeBuildEnvironmentVariable.init(key:value:))
        }
    }

    private struct CreateXCFrameworkCommand: XcodeBuildCommand {
        struct Context: XcodeBuildContext {
            let package: Package
            let target: ResolvedTarget
            let buildConfiguration: BuildConfiguration
            let sdks: Set<SDK>
            let debugSymbolPaths: [AbsolutePath]?
        }
        let context: Context
        let subCommand: String = "-create-xcframework"
        let outputDir: AbsolutePath

        var xcFrameworkPath: AbsolutePath {
            outputDir.appending(component: "\(context.target.name.packageNamed()).xcframework")
        }

        func buildFrameworkPath(sdk: SDK) -> AbsolutePath {
            context.buildXCArchivePath(sdk: sdk)
                .appending(components: "Products", "Library", "Frameworks")
                .appending(component: "\(context.target.name.packageNamed()).framework")
        }

        var options: [XcodeBuildOption] {
            context.sdks.map { sdk in
                    .init(key: "framework", value: buildFrameworkPath(sdk: sdk).pathString)
            }
            +
            (context.debugSymbolPaths.flatMap {
                $0.map { .init(key: "debug-symbols", value: $0.pathString) }
            } ?? [])
            + [.init(key: "output", value: xcFrameworkPath.pathString)]
        }

        var environmentVariables: [XcodeBuildEnvironmentVariable] {
            []
        }
    }
}

extension Package {
    var archivesPath: AbsolutePath {
        workspaceDirectory.appending(component: "archives")
    }
}

extension Compiler.ArchiveCommand.Context {
    var xcArchivePath: AbsolutePath {
        buildXCArchivePath(sdk: sdk)
    }
}
