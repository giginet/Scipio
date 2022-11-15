import Foundation
import PackageGraph

struct Compiler<E: Executor> {
    let rootPackage: Package
    let cacheStorage: (any CacheStorage)?
    let fileSystem: any FileSystem
    private let xcodebuild: XcodeBuildClient<E>
    private let extractor: DwarfExtractor<E>

    enum BuildMode {
        case createPackage
        case prepareDependencies
    }

    init(
        rootPackage: Package,
        cacheStorage: (any CacheStorage)?,
        executor: E = ProcessExecutor(),
        fileSystem: any FileSystem = localFileSystem
    ) {
        self.rootPackage = rootPackage
        self.cacheStorage = cacheStorage
        self.fileSystem = fileSystem
        self.xcodebuild = XcodeBuildClient(executor: executor)
        self.extractor = DwarfExtractor(executor: executor)
    }

    private func buildArtifactsDirectoryPath(buildConfiguration: BuildConfiguration, sdk: SDK) -> URL {
        rootPackage.workspaceDirectory.appendingPathComponent("\(buildConfiguration.settingsValue)-\(sdk.name)")
    }

    private func buildDebugSymbolPath(buildConfiguration: BuildConfiguration, sdk: SDK, target: ResolvedTarget) -> URL {
        buildArtifactsDirectoryPath(buildConfiguration: buildConfiguration, sdk: sdk).appendingPathComponent("\(target).framework.dSYM")
    }

    func build(mode: BuildMode, buildOptions: BuildOptions, outputDir: URL, isCacheEnabled: Bool) async throws {
        let cacheSystem = CacheSystem(rootPackage: rootPackage,
                                      buildOptions: buildOptions,
                                      outputDirectory: outputDir,
                                      storage: cacheStorage)

        logger.info("🗑️ Cleaning \(rootPackage.name)...")
        try await xcodebuild.clean(package: rootPackage)

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
                let xcframeworkPath = outputDir.appendingPathComponent(frameworkName)
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
                            try fileSystem.removeFileTree(at: xcframeworkPath)
                        }
                    }
                }

                let frameworkPath = outputDir.appendingPathComponent(frameworkName)
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
                                   outputDirectory: URL) async throws {
        let sdkNames = sdks.map(\.displayName).joined(separator: ", ")
        logger.info("📦 Building \(target.name) for \(sdkNames)")

        for sdk in sdks {
            try await xcodebuild.archive(package: rootPackage, target: target, buildConfiguration: buildConfiguration, sdk: sdk)
        }

        logger.info("🚀 Combining into XCFramework...")

        let debugSymbolPaths: [URL]?
        if isDebugSymbolsEmbedded {
            debugSymbolPaths = try await extractDebugSymbolPaths(target: target,
                                                                 buildConfiguration: buildConfiguration,
                                                                 sdks: sdks)
        } else {
            debugSymbolPaths = nil
        }

        try await xcodebuild.createXCFramework(
            package: rootPackage,
            target: target,
            buildConfiguration: buildConfiguration,
            sdks: sdks,
            debugSymbolPaths: debugSymbolPaths,
            outputDir: outputDirectory
        )
    }

    private func extractDebugSymbolPaths(
        target: ResolvedTarget,
        buildConfiguration: BuildConfiguration,
        sdks: Set<SDK>
    ) async throws -> [URL] {
        let debugSymbols: [DebugSymbol] = sdks.compactMap { sdk in
            let dsymPath = buildDebugSymbolPath(buildConfiguration: buildConfiguration, sdk: sdk, target: target)
            guard fileSystem.exists(dsymPath) else { return nil }
            return DebugSymbol(dSYMPath: dsymPath,
                               target: target,
                               sdk: sdk,
                               buildConfiguration: buildConfiguration)
        }
        // You can use AsyncStream
        var symbolMapPaths: [URL] = []
        for dSYMs in debugSymbols {
            let maps = try await self.extractor.dump(dwarfPath: dSYMs.dwarfPath)
            let paths = maps.values.map { uuid in
                buildArtifactsDirectoryPath(buildConfiguration: dSYMs.buildConfiguration, sdk: dSYMs.sdk)
                    .appendingPathComponent("\(uuid.uuidString).bcsymbolmap")
            }
            symbolMapPaths.append(contentsOf: paths)
        }
        return debugSymbols.map { $0.dSYMPath } + symbolMapPaths
    }

    private func dependenciesPackages(for package: Package) -> [ResolvedPackage] {
        package.graph.packages
            .filter { $0.manifest.displayName != package.manifest.displayName }
    }
}

extension Package {
    var archivesPath: URL {
        workspaceDirectory.appendingPathComponent("archives")
    }
}
