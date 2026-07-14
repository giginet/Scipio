import Foundation
import Darwin
import os

/// Collects process output from a single non-blocking file handle.
///
/// The reader owns the handle's readability notifications and closes the handle
/// when collection finishes. `readabilityHandler` drains while the process is
/// running, and `terminationHandler` drains once more to capture trailing bytes
/// that Foundation has not delivered yet. The final drain reads only immediately
/// available bytes instead of waiting for pipe EOF because long-lived descendants
/// may inherit the write end and keep it open after the immediate child exits.
final class ProcessOutputReader: Sendable {
    enum DrainResult: Equatable {
        /// The owned handle remains open and has not reached EOF.
        case continueReading

        /// Observation can stop because the reader is closed or has reached EOF.
        case finished
    }

    private struct State {
        var closed = false
        var reachedEndOfFile = false
        var bytes: [UInt8] = []
        var lastStreamOutputTask = Task<Void, Never> {}
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    private let fileHandle: FileHandle
    private let streamOutput: (@Sendable ([UInt8]) async -> Void)?

    /// Creates a reader that manages the supplied file handle until ``close()``.
    ///
    /// The handle must be configured for non-blocking reads before calling
    /// ``startReading()`` or ``drain()``.
    init(fileHandle: FileHandle, streamOutput: (@Sendable ([UInt8]) async -> Void)? = nil) {
        self.fileHandle = fileHandle
        self.streamOutput = streamOutput
    }

    /// Starts draining whenever the file handle reports readable data.
    func startReading() {
        fileHandle.readabilityHandler = { [weak self] handle in
            guard let self else {
                handle.readabilityHandler = nil
                return
            }

            if case .finished = drain() {
                handle.readabilityHandler = nil
            }
        }
    }

    /// Stops receiving readability notifications without closing the handle.
    func stopReading() {
        fileHandle.readabilityHandler = nil
    }

    /// Appends all bytes currently available from the owned file handle.
    ///
    /// Draining is serialized with ``close()`` so the handle cannot be
    /// closed while a read is in progress.
    ///
    /// - Returns: ``DrainResult/finished`` after EOF or closure; otherwise,
    ///   ``DrainResult/continueReading`` so observation can continue.
    @discardableResult
    func drain() -> DrainResult {
        state.withLock { state in
            guard !state.closed else { return .finished }
            guard !state.reachedEndOfFile else { return .finished }

            let result = Self.drainAvailableBytes(from: fileHandle.fileDescriptor)
            for bytes in result.bytes {
                state.bytes.append(contentsOf: bytes)
                if let streamOutput {
                    // Serialize callbacks in the same order as bytes were read.
                    let previousTask = state.lastStreamOutputTask
                    state.lastStreamOutputTask = Task {
                        await previousTask.value
                        await streamOutput(bytes)
                    }
                }
            }

            if result.reachedEndOfFile {
                state.reachedEndOfFile = true
                return .finished
            }

            return .continueReading
        }
    }

    var snapshot: [UInt8] {
        state.withLock { $0.bytes }
    }

    /// Waits for all stream output callbacks scheduled before this call.
    func finishStreaming() async {
        let task = state.withLock { $0.lastStreamOutputTask }
        await task.value
    }

    /// Stops readability notifications and closes the owned handle once.
    ///
    /// Closing is serialized with any in-progress drain so no drain can access
    /// the descriptor concurrently or after this method returns.
    func close() {
        stopReading()
        state.withLock { state in
            guard !state.closed else { return }
            state.closed = true
            try? fileHandle.close()
        }
    }

    /// Reads all bytes currently available on a non-blocking file descriptor.
    ///
    /// `EINTR` retries the read. Any other read error ends the current drain
    /// without treating it as EOF.
    private static func drainAvailableBytes(from fileDescriptor: Int32) -> (bytes: [[UInt8]], reachedEndOfFile: Bool) {
        var chunks: [[UInt8]] = []
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let byteCount = buffer.withUnsafeMutableBytes {
                Darwin.read(fileDescriptor, $0.baseAddress, $0.count)
            }

            switch byteCount {
            case let byteCount where byteCount > 0:
                chunks.append(Array(buffer.prefix(byteCount)))
            case 0:
                return (chunks, true)
            default:
                if errno == EINTR {
                    continue
                }
                return (chunks, false)
            }
        }
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
        let outputReader = ProcessOutputReader(fileHandle: outputHandle, streamOutput: streamOutput)
        let errorReader = ProcessOutputReader(fileHandle: errorHandle)

        let localDecoder = errorDecoder

        do {
            try Self.setNonBlocking(outputHandle.fileDescriptor)
            try Self.setNonBlocking(errorHandle.fileDescriptor)
        } catch {
            outputReader.close()
            errorReader.close()
            throw ProcessExecutorError.unknownError(error)
        }

        outputReader.startReading()
        errorReader.startReading()

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ExecutorResult, Error>) in
            process.terminationHandler = { process in
                outputReader.stopReading()
                errorReader.stopReading()

                Task {
                    outputReader.drain()
                    errorReader.drain()
                    outputReader.close()
                    errorReader.close()
                    await outputReader.finishStreaming()

                    let result = FoundationProcessResult(
                        arguments: arguments,
                        exitStatus: exitStatus(of: process),
                        output: .success(outputReader.snapshot),
                        stderrOutput: .success(errorReader.snapshot)
                    )

                    switch result.exitStatus {
                    case .terminated(let code) where code == 0:
                        continuation.resume(returning: result)
                    case .terminated:
                        let errorOutput = try? localDecoder.decode(result)
                        continuation.resume(throwing: ProcessExecutorError.terminated(errorOutput: errorOutput))
                    case .signalled(let signal):
                        continuation.resume(throwing: ProcessExecutorError.signalled(signal))
                    }
                }
            }

            do {
                try process.run()
            } catch {
                outputReader.close()
                errorReader.close()
                continuation.resume(throwing: ProcessExecutorError.unknownError(error))
            }
        }
    }

    private static func setNonBlocking(_ fileDescriptor: Int32) throws {
        let flags: Int32
        while true {
            let result = fcntl(fileDescriptor, F_GETFL)
            if result != -1 {
                flags = result
                break
            }
            guard errno == EINTR else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        while fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) == -1 {
            guard errno == EINTR else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
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
