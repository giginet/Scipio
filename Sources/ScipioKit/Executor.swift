import Foundation

private actor ProcessOutputBuffer {
    private(set) var bytes: [UInt8] = []

    func append(_ newBytes: [UInt8]) {
        bytes += newBytes
    }
}

protocol Executor {
    @discardableResult
    func execute(_ arguments: [String]) async throws -> ExecutorResult
}

protocol ErrorDecoder: Sendable {
    func decode(_ result: ExecutorResult) throws -> String?
}

enum ProcessExitStatus {
    case terminated(code: Int32)
    case signalled(signal: Int32)
}

protocol ExecutorResult: Sendable {
    var arguments: [String] { get }
    /// The environment with which the process was launched.
    var environment: [String: String] { get }

    /// The exit status of the process.
    var exitStatus: ProcessExitStatus { get }

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

struct FoundationProcessResult: ExecutorResult, Sendable {
    let arguments: [String]
    let environment: [String: String]
    let exitStatus: ProcessExitStatus
    var output: Result<[UInt8], Swift.Error>
    var stderrOutput: Result<[UInt8], Swift.Error>

    mutating func setOutput(_ newValue: Result<[UInt8], Swift.Error>) {
        self.output = newValue
    }

    mutating func setStderrOutput(_ newValue: Result<[UInt8], Swift.Error>) {
        self.stderrOutput = newValue
    }
}

enum ProcessExecutorError: LocalizedError {
    case executableNotFound
    case terminated(errorOutput: String?)
    case signalled(Int32)
    case unknownError(Swift.Error)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Executable not found or invalid"
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

struct ProcessExecutor<Decoder: ErrorDecoder>: Executor, @unchecked Sendable {
    private let decoder: Decoder
    init(decoder: Decoder = StandardErrorOutputDecoder()) {
        self.decoder = decoder
    }

    var streamOutput: (@Sendable ([UInt8]) -> Void)?

    func execute(_ arguments: [String]) async throws -> ExecutorResult {
        logger.debug("\(arguments.joined(separator: " "))")

        // Validate arguments
        guard !arguments.isEmpty else {
            throw ProcessExecutorError.executableNotFound
        }

        guard let executable = arguments.first, !executable.isEmpty else {
            throw ProcessExecutorError.executableNotFound
        }

        // Validate executable exists
        if !FileManager.default.fileExists(atPath: executable) {
            throw ProcessExecutorError.executableNotFound
        }
        
        let executableURL = URL(filePath: executable)

        let process = Foundation.Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = Array(arguments.dropFirst())
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = ProcessInfo.processInfo.environment

        let outputHandle = stdoutPipe.fileHandleForReading
        let errorHandle = stderrPipe.fileHandleForReading

        let outputBuffer = ProcessOutputBuffer()
        let errorBuffer = ProcessOutputBuffer()

        let localStreamOutput = streamOutput
        let localDecoder = decoder

        let outputTask = Task {
            for try await data in outputHandle.byteStream() {
                let bytes = [UInt8](data)
                localStreamOutput?(bytes)
                await outputBuffer.append(bytes)
            }
        }

        let errorOutputTask = Task {
            for try await data in errorHandle.byteStream() {
                let bytes = [UInt8](data)
                await errorBuffer.append(bytes)
            }
        }

        do {
            try process.run()
        } catch {
            throw ProcessExecutorError.unknownError(error)
        }

        try await outputTask.value
        try await errorOutputTask.value

        // Wait for process to complete
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ExecutorResult, Error>) in
            process.terminationHandler = { process in
                Task {
                    // Clean up handlers
                    outputHandle.readabilityHandler = nil
                    errorHandle.readabilityHandler = nil

                    // Read any remaining data
                    let remainingStdout = outputHandle.readDataToEndOfFile()
                    let remainingStderr = errorHandle.readDataToEndOfFile()

                    if !remainingStdout.isEmpty {
                        let bytes = [UInt8](remainingStdout)
                        localStreamOutput?(bytes)
                        await outputBuffer.append(bytes)
                    }

                    if !remainingStderr.isEmpty {
                        let bytes = [UInt8](remainingStderr)
                        await errorBuffer.append(bytes)
                    }

                    // Close file handles
                    try? outputHandle.close()
                    try? errorHandle.close()

                    let exitStatus: ProcessExitStatus
                    if process.terminationReason == .exit {
                        exitStatus = .terminated(code: process.terminationStatus)
                    } else {
                        exitStatus = .signalled(signal: process.terminationStatus)
                    }

                    let finalOutputBuffer = await outputBuffer.bytes
                    let finalErrorBuffer = await errorBuffer.bytes

                    let result = FoundationProcessResult(
                        arguments: arguments,
                        environment: process.environment ?? [:],
                        exitStatus: exitStatus,
                        output: .success(finalOutputBuffer),
                        stderrOutput: .success(finalErrorBuffer)
                    )

                    switch exitStatus {
                    case .terminated(let code) where code == 0:
                        continuation.resume(returning: result)
                    case .terminated:
                        do {
                            let errorOutput = try localDecoder.decode(result)
                            continuation.resume(throwing: ProcessExecutorError.terminated(errorOutput: errorOutput))
                        } catch {
                            continuation.resume(throwing: ProcessExecutorError.terminated(errorOutput: nil))
                        }
                    case .signalled(let signal):
                        continuation.resume(throwing: ProcessExecutorError.signalled(signal))
                    }
                }
            }
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

struct StandardErrorOutputDecoder: ErrorDecoder, Sendable {
    func decode(_ result: ExecutorResult) throws -> String? {
        try result.unwrapStdErrOutput()
    }
}

struct StandardOutputDecoder: ErrorDecoder, Sendable {
    func decode(_ result: ExecutorResult) throws -> String? {
        try result.unwrapOutput()
    }
}

extension FileHandle {
    fileprivate func byteStream() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            self.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    continuation.finish()
                    handle.readabilityHandler = nil
                } else {
                    continuation.yield(data)
                }
            }

            continuation.onTermination = { @Sendable _ in
                self.readabilityHandler = nil
            }
        }
    }
}
