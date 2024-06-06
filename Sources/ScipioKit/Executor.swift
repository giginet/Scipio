import Foundation
import class TSCBasic.Process
import struct TSCBasic.ProcessResult

protocol Executor {
    @discardableResult
    func execute(_ arguments: [String]) async throws -> any ExecutorResult
}

protocol ErrorDecoder {
    func decode(_ result: any ExecutorResult) throws -> String?
}

protocol ExecutorResult {
    var arguments: [String] { get }
    /// The environment with which the process was launched.
    var environment: [String: String] { get }

    /// The exit status of the process.
    var exitStatus: ProcessResult.ExitStatus { get }

    /// The output bytes of the process. Available only if the process was
    /// asked to redirect its output and no stdout output closure was set.
    var output: Result<[UInt8], (any Swift.Error)> { get }

    /// The output bytes of the process. Available only if the process was
    /// asked to redirect its output and no stderr output closure was set.
    var stderrOutput: Result<[UInt8], (any Swift.Error)> { get }
}

extension Executor {
    @discardableResult
    func execute(_ arguments: String...) async throws -> any ExecutorResult {
        try await execute(arguments)
    }
}

extension ProcessResult {
    mutating func setOutput(_ newValue: Result<[UInt8], (any Swift.Error)>) {
        self = ProcessResult(
            arguments: arguments,
            environment: environment,
            exitStatus: exitStatus,
            output: newValue,
            stderrOutput: stderrOutput
        )
    }

    mutating func setStderrOutput(_ newValue: Result<[UInt8], (any Swift.Error)>) {
        self = ProcessResult(
            arguments: arguments,
            environment: environment,
            exitStatus: exitStatus,
            output: output,
            stderrOutput: newValue
        )
    }
}

extension ProcessResult: ExecutorResult { }

enum ProcessExecutorError: LocalizedError {
    case terminated(errorOutput: String?)
    case signalled(Int32)
    case unknownError(any Swift.Error)

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

struct ProcessExecutor<Decoder: ErrorDecoder>: Executor {
    private let decoder: Decoder
    init(decoder: Decoder = StandardErrorOutputDecoder()) {
        self.decoder = decoder
    }

    var streamOutput: (([UInt8]) -> Void)?
    var collectsOutput: Bool = true

    func execute(_ arguments: [String]) async throws -> any ExecutorResult {
        logger.debug("\(arguments.joined(separator: " "))")

        var outputBuffer: [UInt8] = []
        var errorBuffer: [UInt8] = []

        let outputRedirection: Process.OutputRedirection = .stream(
            stdout: { bytes in
                streamOutput?(bytes)

                if collectsOutput {
                    outputBuffer += bytes
                }
            },
            stderr: { (bytes) in
                errorBuffer += bytes
            }
        )

        let process = Process(
            arguments: arguments,
            outputRedirection: outputRedirection
        )

        var result: ProcessResult
        do {
            try process.launch()
            result = try await process.waitUntilExit()
        } catch {
            throw ProcessExecutorError.unknownError(error)
        }

        // respects failure state
        result.setOutput(result.output.map { _ in outputBuffer })
        result.setStderrOutput(result.stderrOutput.map { _ in errorBuffer })

        switch result.exitStatus {
        case .terminated(let code) where code == 0:
            return result
        case .terminated:
            let errorOutput = try? decoder.decode(result)
            throw ProcessExecutorError.terminated(errorOutput: errorOutput)
        case .signalled(let signal):
            throw ProcessExecutorError.signalled(signal)
        }
    }
}

extension ExecutorResult {
    func unwrapOutput() throws -> String {
        switch output {
        case .success(let data):
            return String(decoding: Data(data), as: UTF8.self)
        case .failure(let error):
            throw error
        }
    }

    func unwrapStdErrOutput() throws -> String {
        switch stderrOutput {
        case .success(let data):
            return String(decoding: Data(data), as: UTF8.self)
        case .failure(let error):
            throw error
        }
    }
}

struct StandardErrorOutputDecoder: ErrorDecoder {
    func decode(_ result: any ExecutorResult) throws -> String? {
        try result.unwrapStdErrOutput()
    }
}

struct StandardOutputDecoder: ErrorDecoder {
    func decode(_ result: any ExecutorResult) throws -> String? {
        try result.unwrapOutput()
    }
}
