import Foundation
import PackageGraph
import TSCBasic

enum SDK: String {
    case iOS = "iphoneos"
    case iOSSimulator = "iphonesimulator"

    var name: String {
        rawValue
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

private func buildXCArchivePath(package: Package, target: ResolvedTarget, sdk: SDK) -> AbsolutePath {
    package.archivesPath.appending(component: "\(target.name)_\(sdk.name).xcarchive")
}

struct Compiler<E: Executor> {
    let package: Package
    let projectPath: AbsolutePath
    let executor: E
    let fileSystem: any FileSystem

    init(package: Package, projectPath: AbsolutePath, executor: E, fileSystem: any FileSystem = localFileSystem) {
        self.package = package
        self.projectPath = projectPath
        self.executor = executor
        self.fileSystem = fileSystem
    }

    func build(outputDir: AbsolutePath) async throws {
        let targets = targetsForBuild(for: package)

        logger.info("Cleaning \(package.name)...")
        try await execute(CleanCommand(
            projectPath: projectPath,
            buildDirectory: package.buildDirectory
        ))

        for target in targets {
            logger.info("Building framework \(target.name)")
            try await execute(ArchiveCommand(package: package, target: target, projectPath: projectPath, sdk: .iOS))
            try await execute(ArchiveCommand(package: package, target: target, projectPath: projectPath, sdk: .iOSSimulator))

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
        var package: Package
        var target: ResolvedTarget
        var projectPath: AbsolutePath
        var sdk: SDK
        var xcArchivePath: AbsolutePath {
            buildXCArchivePath(package: package, target: target, sdk: sdk)
        }

        let subCommand: String = "archive"
        var options: [Pair] {
            [
                ("project", projectPath.pathString),
                ("configuration", "Release"),
                ("scheme", target.name),
                ("archivePath", xcArchivePath.pathString),
                ("destination", sdk.destination),
                ("sdk", sdk.name),
            ].map(Pair.init(key:value:))
        }

        var environmentVariables: [Pair] {
            [
                ("BUILD_DIR", package.buildDirectory.pathString),
                ("SKIP_INSTALL", "NO"),
                ("BUILD_LIBRARY_FOR_DISTRIBUTION", "YES")
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

extension Compiler where E == ProcessExecutor {
    init(package: Package, projectPath: AbsolutePath) {
        self.init(package: package, projectPath: projectPath, executor: E())
    }
}

extension Package {
    fileprivate var archivesPath: AbsolutePath {
        buildDirectory.appending(component: "archives")
    }
}
