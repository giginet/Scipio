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

struct Compiler<E: Executor> {
    let package: Package
    let executor: E
    let fileSystem: any FileSystem

    init(package: Package, executor: E = ProcessExecutor(), fileSystem: any FileSystem = localFileSystem) {
        self.package = package
        self.executor = executor
        self.fileSystem = fileSystem
    }

    func build(outputDir: AbsolutePath) async throws {
        let targets = targetsForBuild(for: package)

        logger.info("Cleaning \(package.name)...")
        try await execute(CleanCommand(
            projectPath: package.projectPath,
            buildDirectory: package.workspaceDirectory
        ))

        for target in targets {
            logger.info("Building framework \(target.name)")
            try await execute(ArchiveCommand(context: .init(package: package, target: target, buildConfiguration: .debug, sdk: .iOS)))

            logger.info("Combining into XCFramework...")
            try await execute(CreateXCFrameworkCommand(package: package, target: target, sdks: [.iOS, .iOSSimulator], outputDir: outputDir))
        }
        // TODO Error handling
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
        struct Context {
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
        let subCommand: String = "-create-xcframework"
        let package: Package
        let target: ResolvedTarget
        let sdks: [SDK]
        let outputDir: AbsolutePath

        var xcFrameworkPath: AbsolutePath {
            outputDir.appending(component: "\(target.name).xcframework")
        }

        func buildFrameworkPath(package: Package, target: ResolvedTarget, sdk: SDK) -> AbsolutePath {
            buildXCArchivePath(package: package, target: target, sdk: sdk)
                .appending(components: "Products", "Library", "Frameworks")
                .appending(component: "\(target.name).framework")
        }

        var options: [Pair] {
            sdks.map { sdk in
                .init(key: "framework", value: buildFrameworkPath(package: package, target: target, sdk: sdk).pathString)
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

extension Compiler.ArchiveCommand.Context {
    fileprivate var xcArchivePath: AbsolutePath {
        buildXCArchivePath(package: package, target: target, sdk: sdk)
    }

    fileprivate var projectPath: AbsolutePath {
        package.projectPath
    }
}

private func buildXCArchivePath(package: Package, target: ResolvedTarget, sdk: SDK) -> AbsolutePath {
    package.archivesPath.appending(component: "\(target.name)_\(sdk.name).xcarchive")
}
