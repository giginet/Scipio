import Foundation
import PackageGraph
import TSCBasic

enum SDK {
    case iOS
    case iOSSimulator

    var name: String {
        switch self {
        case .iOS:
            return "iphoneos"
        case .iOSSimulator:
            return "iphonesimulator"
        }
    }

    var destination: String {
        switch self {
        case .iOS:
            return "generic/platform=iOS"
        case .iOSSimulator:
            return "generic/platform=iOS Simulator"
        }
    }
}

struct Pair {
    var key: String
    var value: String?
}

protocol XcodeBuildCommand {
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

enum BuildConfiguration {
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
    let package: Package
    let executor: E
    let fileSystem: any FileSystem
    private let extractor: DwarfExtractor<E>

    init(package: Package, executor: E = ProcessExecutor(), fileSystem: any FileSystem = localFileSystem) {
        self.package = package
        self.executor = executor
        self.fileSystem = fileSystem
        self.extractor = DwarfExtractor(executor: executor)
    }

    private func buildArtifactsDirectoryPath(buildConfiguration: BuildConfiguration, sdk: SDK) -> AbsolutePath {
        package.workspaceDirectory.appending(component: "\(buildConfiguration.settingsValue)-\(sdk.name)")
    }

    private func buildDebugSymbolPath(buildConfiguration: BuildConfiguration, sdk: SDK, target: ResolvedTarget) -> AbsolutePath {
        buildArtifactsDirectoryPath(buildConfiguration: buildConfiguration, sdk: sdk).appending(component: "\(target).framework.dSYM")
    }

    func build(outputDir: AbsolutePath) async throws {
        let targets = targetsForBuild(for: package)

        logger.info("Cleaning \(package.name)...")
        try await execute(CleanCommand(
            projectPath: package.projectPath,
            buildDirectory: package.workspaceDirectory
        ))

        let buildConfiguration: BuildConfiguration = .release // TODO setting from option
        let sdks: [SDK] = [.iOS, .iOSSimulator]

        for target in targets {
            logger.info("Building framework \(target.name)")
            for sdk in sdks {
                try await execute(ArchiveCommand(context: .init(package: package, target: target, buildConfiguration: buildConfiguration, sdk: sdk)))
            }

            logger.info("Combining into XCFramework...")

            let debugSymbolPaths = try await extractDebugSymbolPaths(target: target,
                                                                     buildConfiguration: buildConfiguration,
                                                                     sdks: sdks)

            try await execute(CreateXCFrameworkCommand(
                context: .init(package: package,
                               target: target,
                               buildConfiguration: buildConfiguration,
                               sdks: sdks,
                               debugSymbolPaths: debugSymbolPaths),
                outputDir: outputDir
            ))
        }
        // TODO Error handling
    }

    private func extractDebugSymbolPaths(target: ResolvedTarget, buildConfiguration: BuildConfiguration, sdks: [SDK]) async throws -> [AbsolutePath] {
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
    func execute<Command: XcodeBuildCommand>(_ command: Command) async throws -> ExecutorResult {
        try await executor.execute(command.buildArguments())
    }

    private func targetsForBuild(for package: Package) -> [ResolvedTarget] {
        package.graph.allTargets
            .filter { $0.type == .library }
            .filter { $0.name != package.name }
    }

    struct CleanCommand: XcodeBuildCommand {
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

    struct ArchiveCommand: XcodeBuildCommand {
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
                //                ("BUILD_LIBRARY_FOR_DISTRIBUTION", "YES"),
                //                ("DEBUG_INFORMATION_FORMAT", "dwarf-with-dsym") // TODO
            ].map(Pair.init(key:value:))
        }
    }

    struct CreateXCFrameworkCommand: XcodeBuildCommand {
        struct Context: BuildContext {
            let package: Package
            let target: ResolvedTarget
            let buildConfiguration: BuildConfiguration
            let sdks: [SDK]
            let debugSymbolPaths: [AbsolutePath]
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
            // TODO bcsymbolmap
            +
            context.debugSymbolPaths.map {
                .init(key: "debug-symbols", value: $0.pathString)
            }
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

