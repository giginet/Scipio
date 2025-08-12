import Foundation

/// Buffer to collect process output bytes.
private actor ProcessOutputBuffer {
    private(set) var bytes: [UInt8] = []

    func append(_ newBytes: [UInt8]) {
        bytes += newBytes
    }
}

@_spi(Internals)
public protocol Executor: Sendable {
    /// Executes the command with the given arguments and environment variables.
    ///
    /// - Parameters:
    ///   - arguments: Command-line arguments for the process.
    ///   - environment: Complete set of environment variables for the process.
    ///     If `nil`, the current environment is used.
    ///     If non-nil, it **replaces** the entire environment.
    ///     Use `ProcessInfo.processInfo.environment` to preserve existing values if needed.
    ///
    /// - Note:
    ///   This does not merge with the existing environment.
    @discardableResult
    func execute(_ arguments: [String], environment: [String: String]?) async throws -> ExecutorResult
}

@_spi(Internals)
public protocol ErrorDecoder: Sendable {
    func decode(_ result: ExecutorResult) throws -> String?
}

@_spi(Internals)
public enum ProcessExitStatus: Sendable, Equatable {
    case terminated(code: Int32)
    case signalled(signal: Int32)
}

@_spi(Internals)
public protocol ExecutorResult: Sendable {
    var arguments: [String] { get }

    /// The exit status of the process.
    var exitStatus: ProcessExitStatus { get }

    /// The output bytes of the process. Available only if the process was
    /// asked to redirect its output and no stdout output closure was set.
    var output: Result<[UInt8], Swift.Error> { get }

    /// The output bytes of the process. Available only if the process was
    /// asked to redirect its output and no stderr output closure was set.
    var stderrOutput: Result<[UInt8], Swift.Error> { get }
}

public extension Executor {
    @discardableResult
    func execute(_ arguments: [String]) async throws -> ExecutorResult {
        try await execute(arguments, environment: nil)
    }

    @discardableResult
    func execute(_ arguments: String...) async throws -> ExecutorResult {
        try await execute(arguments)
    }
}

@_spi(Internals)
public struct FoundationProcessResult: ExecutorResult, Sendable {
    public let arguments: [String]
    public let exitStatus: ProcessExitStatus
    public var output: Result<[UInt8], Swift.Error>
    public var stderrOutput: Result<[UInt8], Swift.Error>
}

@_spi(Internals)
public enum ProcessExecutorError: LocalizedError {
    case executableNotFound
    case terminated(errorOutput: String?)
    case signalled(Int32)
    case unknownError(Swift.Error)

    public var errorDescription: String? {
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

@_spi(Internals)
public struct ProcessExecutor<Decoder: ErrorDecoder>: Executor, Sendable {
    private let errorDecoder: Decoder
    private let fileSystem: any FileSystem

    public init(errorDecoder: Decoder = StandardErrorOutputDecoder(), fileSystem: some FileSystem = LocalFileSystem.default) {
        self.errorDecoder = errorDecoder
        self.fileSystem = fileSystem
    }

    public var streamOutput: (@Sendable ([UInt8]) async -> Void)?

    public func execute(_ arguments: [String], environment: [String: String]?) async throws -> ExecutorResult {
        guard let executable = arguments.first, !executable.isEmpty else {
            throw ProcessExecutorError.executableNotFound
        }

        let executableURL = URL(filePath: executable)
        guard fileSystem.exists(executableURL), fileSystem.isFile(executableURL) else {
            throw ProcessExecutorError.executableNotFound
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = Array(arguments.dropFirst())
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Completely replace the process environment if provided.
        // If nil, the process inherits the current environment.
        if let environment {
            process.environment = environment
        }

        let outputHandle = stdoutPipe.fileHandleForReading
        let errorHandle = stderrPipe.fileHandleForReading

        let outputBuffer = ProcessOutputBuffer()
        let errorBuffer = ProcessOutputBuffer()

        let localStreamOutput = streamOutput
        let localDecoder = errorDecoder

        let outputTask = Task {
            // Workaround to avoid "Bad file descriptor" error when executing processes at high concurrency.
            // Investigate this section if command output is missing
            // ref: https://github.com/swiftlang/swift/issues/57827
            defer { try? outputHandle.close() }
            for try await data in outputHandle.byteStream() {
                let bytes = [UInt8](data)
                await localStreamOutput?(bytes)
                await outputBuffer.append(bytes)
            }
            return await outputBuffer.bytes
        }

        let errorOutputTask = Task {
            // Workaround to avoid "Bad file descriptor" error when executing processes at high concurrency.
            // Investigate this section if command output is missing
            // ref: https://github.com/swiftlang/swift/issues/57827
            defer { try? errorHandle.close() }
            for try await data in errorHandle.byteStream() {
                let bytes = [UInt8](data)
                await errorBuffer.append(bytes)
            }
            return await errorBuffer.bytes
        }

        do {
            try process.run()
        } catch {
            throw ProcessExecutorError.unknownError(error)
        }

        process.waitUntilExit()

        let finalOutput = try await outputTask.value
        let finalErrorOutput = try await errorOutputTask.value

        // Wait for process to complete
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ExecutorResult, Error>) in
            process.terminationHandler = { process in
                outputHandle.readabilityHandler = nil
                errorHandle.readabilityHandler = nil

                let exitStatus = exitStatus(of: process)

                let result = FoundationProcessResult(
                    arguments: arguments,
                    exitStatus: exitStatus,
                    output: .success(finalOutput),
                    stderrOutput: .success(finalErrorOutput)
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

    /// Determines the exit status of the process based on its termination reason.
    private func exitStatus(of process: Process) -> ProcessExitStatus {
        if process.terminationReason == .exit {
            .terminated(code: process.terminationStatus)
        } else {
            .signalled(signal: process.terminationStatus)
        }
    }
}

public extension ExecutorResult {
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

@_spi(Internals)
public struct StandardErrorOutputDecoder: ErrorDecoder, Sendable {
    public init() {}

    public func decode(_ result: ExecutorResult) throws -> String? {
        try result.unwrapStdErrOutput()
    }
}

@_spi(Internals)
public struct StandardOutputDecoder: ErrorDecoder, Sendable {
    public init() {}

    public func decode(_ result: ExecutorResult) throws -> String? {
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
