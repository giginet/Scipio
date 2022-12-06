import Foundation
import PackageGraph

struct Compiler<E: Executor> {
    let rootPackage: Package
    let buildOptions: BuildOptions
    let fileSystem: any FileSystem
    private let xcodebuild: XcodeBuildClient<E>
    private let extractor: DwarfExtractor<E>

    init(
        rootPackage: Package,
        buildOptions: BuildOptions,
        executor: E = ProcessExecutor(),
        fileSystem: any FileSystem = localFileSystem
    ) {
        self.rootPackage = rootPackage
        self.buildOptions = buildOptions
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

    func clean() async throws {
        logger.info("🗑️ Cleaning \(rootPackage.name)...")
        try await xcodebuild.clean(package: rootPackage)
    }

    func createXCFramework(target: ResolvedTarget,
                           outputDirectory: URL) async throws {
        let buildConfiguration = buildOptions.buildConfiguration
        let sdks = extractSDKs(isSimulatorSupported: buildOptions.isSimulatorSupported)

        let sdkNames = sdks.map(\.displayName).joined(separator: ", ")
        logger.info("📦 Building \(target.name) for \(sdkNames)")

        for sdk in sdks {
            try await xcodebuild.archive(package: rootPackage, target: target, buildConfiguration: buildConfiguration, sdk: sdk)
        }

        logger.info("🚀 Combining into XCFramework...")

        let debugSymbolPaths: [URL]?
        if buildOptions.isDebugSymbolsEmbedded {
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
            let dumpedDSYMsMaps = try await self.extractor.dump(dwarfPath: dSYMs.dwarfPath)
            let paths = dumpedDSYMsMaps.values.map { uuid in
                buildArtifactsDirectoryPath(buildConfiguration: dSYMs.buildConfiguration, sdk: dSYMs.sdk)
                    .appendingPathComponent("\(uuid.uuidString).bcsymbolmap")
            }
            symbolMapPaths.append(contentsOf: paths)
        }
        return debugSymbols.map { $0.dSYMPath } + symbolMapPaths
    }

    private func extractSDKs(isSimulatorSupported: Bool) -> Set<SDK> {
        if isSimulatorSupported {
            return Set(buildOptions.sdks.flatMap { $0.extractForSimulators() })
        } else {
            return Set(buildOptions.sdks)
        }
    }
}

extension Package {
    var archivesPath: URL {
        workspaceDirectory.appendingPathComponent("archives")
    }
}
