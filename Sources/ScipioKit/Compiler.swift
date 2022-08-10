import Foundation
import PackageGraph
import TSCBasic

private struct Pair {
    var key: String
    var value: String?
}

private protocol XcodeBuildCommand {
    var subCommand: String { get }
    var options: [Pair] { get }
    var environmentVariables: [Pair] { get }
}

extension XcodeBuildCommand {
    func buildArguments() -> [String] {
        ["/usr/bin/xcrun", "xcodebuild"]
        + environmentVariables.map { pair in
            "\(pair.key)=\(pair.value!)"
        }
        + [subCommand]
        + options.flatMap { option in
            if let value = option.value {
                return ["-\(option.key)", value]
            } else {
                return ["-\(option.key)"]
            }
        }
    }
}

public enum BuildConfiguration: Codable {
    case debug
    case release

    var settingsValue: String {
        switch self {
        case .debug: return "Debug"
        case .release: return "Release"
        }
    }
}

private protocol BuildContext {
    var package: Package { get }
    var target: ResolvedTarget { get }
    var buildConfiguration: BuildConfiguration { get }
}

struct Compiler<E: Executor> {
    let rootPackage: Package
    let executor: E
    let fileSystem: any FileSystem
    private let extractor: DwarfExtractor<E>

    init(rootPackage: Package, executor: E = ProcessExecutor(), fileSystem: any FileSystem = localFileSystem) {
        self.rootPackage = rootPackage
        self.executor = executor
        self.fileSystem = fileSystem
        self.extractor = DwarfExtractor(executor: executor)
    }

    private func buildArtifactsDirectoryPath(buildConfiguration: BuildConfiguration, sdk: SDK) -> AbsolutePath {
        rootPackage.workspaceDirectory.appending(component: "\(buildConfiguration.settingsValue)-\(sdk.name)")
    }

    private func buildDebugSymbolPath(buildConfiguration: BuildConfiguration, sdk: SDK, target: ResolvedTarget) -> AbsolutePath {
        buildArtifactsDirectoryPath(buildConfiguration: buildConfiguration, sdk: sdk).appending(component: "\(target).framework.dSYM")
    }

    func build(buildOptions: BuildOptions, outputDir: AbsolutePath, isCacheEnabled: Bool, force: Bool) async throws {
        let cacheSystem = CacheSystem(rootPackage: rootPackage, outputDirectory: outputDir, buildOptions: buildOptions)

        logger.info("🗑️ Cleaning \(rootPackage.name)...")
        try await execute(CleanCommand(
            projectPath: rootPackage.projectPath,
            buildDirectory: rootPackage.workspaceDirectory
        ))

        let buildConfiguration: BuildConfiguration = buildOptions.buildConfiguration
        let sdks: Set<SDK> // TODO load from manifest
        if buildOptions.isSimulatorSupported {
            sdks = SDK.iOS.extractForSimulators()
        } else {
            sdks = [.iOS]
        }

        let packages = packagesForBuild(for: rootPackage)
        for subPackage in packages {
            for target in subPackage.targets {
                let xcframeworkPath = outputDir.appending(component: "\(target.name).xcframework")
                let exists = fileSystem.exists(xcframeworkPath)

                if isCacheEnabled {
                    let isValidCache = try await cacheSystem.existsValidCache(package: subPackage, target: target)
                    if isValidCache {
                        logger.warning("✅ Valid \(target.name).xcframework is exists. Skip building.")
                        continue
                    } else {
                        logger.warning("⚠️ Existing \(target.name).xcframework is outdated. Start re-building...")
                        try fileSystem.removeFileTree(xcframeworkPath)
                    }
                }

                if exists {
                    logger.warning("\(target.name).xcframework is already exists")
                    if force {
                        logger.info("💥 Delete \(target.name).xcframework")
                        try fileSystem.removeFileTree(xcframeworkPath)
                    } else {
                        logger.info("☑️ Skip building \(target.name)")
                        continue
                    }
                }
                logger.info("📦 Building \(target.name) for all SDKs")

                for sdk in sdks {
                    try await execute(ArchiveCommand(context: .init(package: rootPackage, target: target, buildConfiguration: buildConfiguration, sdk: sdk)))
                }

                logger.info("🚀 Combining into XCFramework...")

                let debugSymbolPaths: [AbsolutePath]?
                if buildOptions.isDebugSymbolsEmbedded {
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
                    outputDir: outputDir
                ))


                try await cacheSystem.generateVersionFile(package: subPackage, target: target)
            }
            // TODO Error handling
        }
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

    private func packagesForBuild(for package: Package) -> [ResolvedPackage] {
        package.graph.packages
            .filter { $0.manifest.displayName != package.manifest.displayName }
    }

    private struct CleanCommand: XcodeBuildCommand {
        let projectPath: AbsolutePath
        let buildDirectory: AbsolutePath

        let subCommand: String = "clean"
        var options: [Pair] {
            [.init(key: "project", value: projectPath.pathString)]
        }

        var environmentVariables: [Pair] {
            [.init(key: "BUILD_DIR", value: buildDirectory.pathString)]
        }
    }

    fileprivate struct ArchiveCommand: XcodeBuildCommand {
        struct Context: BuildContext {
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
        var options: [Pair] {
            [
                ("project", context.projectPath.pathString),
                ("configuration", context.buildConfiguration.settingsValue),
                ("scheme", context.target.name),
                ("archivePath", xcArchivePath.pathString),
                ("destination", context.sdk.destination),
                ("sdk", context.sdk.name),
            ].map(Pair.init(key:value:))
        }

        var environmentVariables: [Pair] {
            [
                ("BUILD_DIR", context.package.workspaceDirectory.pathString),
                ("SKIP_INSTALL", "NO"),
            ].map(Pair.init(key:value:))
        }
    }

    private struct CreateXCFrameworkCommand: XcodeBuildCommand {
        struct Context: BuildContext {
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
            outputDir.appending(component: "\(context.target.name).xcframework")
        }

        func buildFrameworkPath(sdk: SDK) -> AbsolutePath {
            context.buildXCArchivePath(sdk: sdk)
                .appending(components: "Products", "Library", "Frameworks")
                .appending(component: "\(context.target.name).framework")
        }

        var options: [Pair] {
            context.sdks.map { sdk in
                    .init(key: "framework", value: buildFrameworkPath(sdk: sdk).pathString)
            }
            +
            (context.debugSymbolPaths.flatMap {
                $0.map { .init(key: "debug-symbols", value: $0.pathString) }
            } ?? [])
            + [.init(key: "output", value: xcFrameworkPath.pathString)]
        }

        var environmentVariables: [Pair] {
            []
        }
    }
}

extension Package {
    fileprivate var archivesPath: AbsolutePath {
        workspaceDirectory.appending(component: "archives")
    }
}

extension BuildContext {
    fileprivate func buildXCArchivePath(sdk: SDK) -> AbsolutePath {
        package.archivesPath.appending(component: "\(target.name)_\(sdk.name).xcarchive")
    }

    fileprivate var projectPath: AbsolutePath {
        package.projectPath
    }
}

extension Compiler.ArchiveCommand.Context {
    var xcArchivePath: AbsolutePath {
        buildXCArchivePath(sdk: sdk)
    }
}

