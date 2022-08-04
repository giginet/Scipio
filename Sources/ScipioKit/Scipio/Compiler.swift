import Foundation
import TSCBasic

protocol Executor {
    @discardableResult
    func execute(_ arguments: [String]) async throws -> ExecutorResult
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
    func execute(_ arguments: [String]) async throws -> ExecutorResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ExecutorResult, Error>) in
            let process = Process(arguments: arguments)

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
}

struct Compiler<E: Executor> {
    let projectPath: AbsolutePath
    let executor: E

    init(projectPath: AbsolutePath, executor: E) {
        self.projectPath = projectPath
        self.executor = executor
    }

    func build(package: Package) async throws {
        let targets = package.manifest.targets

        try await executor.execute(buildCommand(package: package, sdk: .iOS))
        try await executor.execute(buildCommand(package: package, sdk: .iOSSimulator))
        // TODO Error handling
    }

    private func buildCommand(package: Package, sdk: SDK) -> [String] {
        [
            "/usr/bin/xcrun",
            "xcodebuild",
            "-project", projectPath.pathString,
            "-configuration", "Debug", // TODO
            "-sdk", sdk.name,
            "BUILD_DIR=\(package.buildDirectory.pathString)"
        ]
        + package.manifest.targets.flatMap { ["-target", $0.name] }
        + ["build"]
    }
}

extension Compiler where E == ProcessExecutor {
    init(projectPath: AbsolutePath) {
        self.init(projectPath: projectPath, executor: E())
    }
}
