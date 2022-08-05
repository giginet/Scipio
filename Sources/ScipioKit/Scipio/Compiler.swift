import Foundation
import PackageGraph
import TSCBasic

struct ExportOptions: Encodable {
    var compileBitcode: Bool
}

private func buildOptionPlistPath(for package: Package) -> AbsolutePath {
    package.buildDirectory.appending(component: "options.plist")
}

protocol Executor {
    @discardableResult
    func execute(_ arguments: [String]) async throws -> ExecutorResult
    func outputStream(_: Data)
    func errorOutputStream(_: Data)
}

protocol ExecutorResult {
    var arguments: [String] { get }
    /// The environment with which the process was launched.
    var environment: [String: String] { get }

    /// The exit status of the process.
    var exitStatus: ProcessResult.ExitStatus { get }

    /// The output bytes of the process. Available only if the process was
    /// asked to redirect its output and no stdout output closure was set.
    var output: Result<[UInt8], Swift.Error> { get }

    /// The output bytes of the process. Available only if the process was
    /// asked to redirect its output and no stderr output closure was set.
    var stderrOutput: Result<[UInt8], Swift.Error> { get }
}

extension Executor {
    func execute(_ arguments: String...) async throws -> ExecutorResult {
        try await execute(arguments)
    }
}

extension ProcessResult: ExecutorResult { }

struct ProcessExecutor: Executor {
    func outputStream(_ data: Data) {
        logger.info("\(String(data: data, encoding: .utf8)!)")
    }

    func errorOutputStream(_ data: Data) {
        logger.error("\(String(data: data, encoding: .utf8)!)")
    }

    func execute(_ arguments: [String]) async throws -> ExecutorResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ExecutorResult, Error>) in
            let process = Process(
                arguments: arguments,
                outputRedirection:
                        .stream(stdout: { outputStream(Data($0)) },
                                stderr: { errorOutputStream(Data($0)) })
            )

            do {
                try process.launch()
                let result = try process.waitUntilExit()
                continuation.resume(with: .success(result))
            } catch {
                continuation.resume(with: .failure(error))
            }
        }
    }
}

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

    @discardableResult
    private func createOptionsPlist() throws -> AbsolutePath {
        let options = ExportOptions(compileBitcode: true)
        let encoder = PropertyListEncoder()
        let data = try encoder.encode(options)
        let outputPath = buildOptionPlistPath(for: package)
        try fileSystem.writeFileContents(outputPath, data: data)
        return outputPath
    }

    func build() async throws {
        let targets = targetsForBuild(for: package)

        logger.info("Cleaning \(package.name)...")
        try await execute(CleanCommand(
            projectPath: projectPath,
            buildDirectory: package.buildDirectory
        ))

        try createOptionsPlist()

        for target in targets {
            logger.info("Building framework \(target.name)")
            try await execute(ArchiveCommand(package: package, target: target, projectPath: projectPath, sdk: .iOS))
            try await execute(ArchiveCommand(package: package, target: target, projectPath: projectPath, sdk: .iOSSimulator))
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

        let subCommand: String = "archive"
        var options: [Pair] {
            [
                ("project", projectPath.pathString),
                ("configuration", "Release"),
                ("scheme", target.name),
                ("archivePath", package.buildDirectory.appending(component: "iphoneos.xcarchive").pathString),
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
}

extension Compiler where E == ProcessExecutor {
    init(package: Package, projectPath: AbsolutePath) {
        self.init(package: package, projectPath: projectPath, executor: E())
    }
}
