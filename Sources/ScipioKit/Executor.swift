import Foundation
import class TSCBasic.Process
import struct TSCBasic.ProcessResult

protocol Executor {
    @discardableResult
    func execute(_ arguments: [String]) async throws -> ExecutorResult
    func outputStream(_: Data)
    func errorOutputStream(_: Data)
}

protocol ErrorDecoder {
    func decode(_ result: ExecutorResult) throws -> String?
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
    @discardableResult
    func execute(_ arguments: String...) async throws -> ExecutorResult {
        try await execute(arguments)
    }
}

extension ProcessResult: ExecutorResult { }

struct ProcessExecutor<Decoder: ErrorDecoder>: Executor {
    enum Error: LocalizedError {
        case terminated(errorOutput: String?)
        case signalled(Int32)
        case unknownError(Swift.Error)

        var errorDescription: String? {
            switch self {
            case .terminated(let errorOutput):
                return [
                    "Execution was terminated:",
                    errorOutput,
                ]
                    .compactMap { $0 }
                    .joined(separator: "\n")
            case .signalled(let signal):
                return "Execution was stopped by signal \(signal)"
            case .unknownError(let error):
                return """
Unknown error occurered.
\(error.localizedDescription)
"""
            }
        }
    }

    private let decoder: Decoder
    init(decoder: Decoder = StandardErrorOutputDecoder()) {
        self.decoder = decoder
    }

    var outputRedirection: TSCBasic.Process.OutputRedirection = .collect

    func outputStream(_ data: Data) {
        logger.trace("\(String(data: data, encoding: .utf8)!)")
    }

    func errorOutputStream(_ data: Data) {
        logger.trace("\(String(data: data, encoding: .utf8)!)")
    }

    func execute(_ arguments: [String]) async throws -> ExecutorResult {
        logger.debug("\(arguments.joined(separator: " "))")
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ExecutorResult, Swift.Error>) in
            let process = Process(
                arguments: arguments,
                outputRedirection: outputRedirection)

//                .stream(stdout: { self.outputStream(Data($0)) },
//                        stderr: { self.errorOutputStream(Data($0)) })

            do {
                try process.launch()
                let result = try process.waitUntilExit()
                switch result.exitStatus {
                case .terminated(let code) where code == 0:
                    continuation.resume(returning: result)
                case .terminated:
                    let errorOutput = try? decoder.decode(result)
                    continuation.resume(throwing: Error.terminated(errorOutput: errorOutput))
                case .signalled(let signal):
                    continuation.resume(throwing: Error.signalled(signal))
                }
            } catch {
                continuation.resume(with: .failure(Error.unknownError(error)))
            }
        }
    }
}

extension ExecutorResult {
    func unwrapOutput() throws -> String {
        switch output {
        case .success(let data):
            return String(data: Data(data), encoding: .utf8)!
        case .failure(let error):
            throw error
        }
    }

    func unwrapStdErrOutput() throws -> String {
        switch stderrOutput {
        case .success(let data):
            return String(data: Data(data), encoding: .utf8)!
        case .failure(let error):
            throw error
        }
    }
}

struct StandardErrorOutputDecoder: ErrorDecoder {
    func decode(_ result: ExecutorResult) throws -> String? {
        try result.unwrapStdErrOutput()
    }
}

struct StandardOutputDecoder: ErrorDecoder {
    func decode(_ result: ExecutorResult) throws -> String? {
        try result.unwrapOutput()
    }
}
