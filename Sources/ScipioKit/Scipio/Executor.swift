import Foundation
import TSCBasic

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
