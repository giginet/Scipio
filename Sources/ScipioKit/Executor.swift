import Foundation
import Darwin
import os

/// Reads currently available process output without waiting for EOF.
///
/// The file descriptor is non-blocking. `readabilityHandler` drains while the
/// process is running, and `terminationHandler` drains once more to capture
/// trailing bytes that Foundation has not delivered yet. This intentionally
/// does not wait for pipe EOF because long-lived descendants may inherit the
/// write end and keep it open after the immediate child exits.
private final class ProcessOutputReader: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: [UInt8]())

    // Serializes async stream callbacks in the same order as bytes were read.
    private let lastStreamOutputTask = OSAllocatedUnfairLock(initialState: Task<Void, Never> {})
    private let streamOutput: (@Sendable ([UInt8]) async -> Void)?

    init(streamOutput: (@Sendable ([UInt8]) async -> Void)? = nil) {
        self.streamOutput = streamOutput
    }

    func drain(from fileDescriptor: Int32) {
        for bytes in Self.drainAvailableBytes(from: fileDescriptor) {
            storage.withLock {
                $0.append(contentsOf: bytes)
            }
            if let streamOutput {
                lastStreamOutputTask.withLock {
                    let previousTask = $0
                    $0 = Task {
                        await previousTask.value
                        await streamOutput(bytes)
                    }
                }
            }
        }
    }

    var snapshot: [UInt8] {
        storage.withLock { $0 }
    }

    func finishStreaming() async {
        let task = lastStreamOutputTask.withLock { $0 }
        await task.value
    }

    /// Reads all bytes currently available on a non-blocking file descriptor.
    /// EAGAIN/EWOULDBLOCK means there is no more data ready right now.
    private static func drainAvailableBytes(from fileDescriptor: Int32) -> [[UInt8]] {
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
                return chunks
            default:
                if errno == EINTR {
                    continue
                }
                return chunks
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
        let outputFileDescriptor = outputHandle.fileDescriptor
        let errorFileDescriptor = errorHandle.fileDescriptor

        let outputReader = ProcessOutputReader(streamOutput: streamOutput)
        let errorReader = ProcessOutputReader()

        let localDecoder = errorDecoder

        Self.setNonBlocking(outputFileDescriptor)
        Self.setNonBlocking(errorFileDescriptor)

        outputHandle.readabilityHandler = { _ in
            outputReader.drain(from: outputFileDescriptor)
        }

        errorHandle.readabilityHandler = { _ in
            errorReader.drain(from: errorFileDescriptor)
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ExecutorResult, Error>) in
            process.terminationHandler = { process in
                outputHandle.readabilityHandler = nil
                errorHandle.readabilityHandler = nil

                Task {
                    outputReader.drain(from: outputFileDescriptor)
                    errorReader.drain(from: errorFileDescriptor)
                    try? outputHandle.close()
                    try? errorHandle.close()
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
                outputHandle.readabilityHandler = nil
                errorHandle.readabilityHandler = nil
                try? outputHandle.close()
                try? errorHandle.close()
                continuation.resume(throwing: ProcessExecutorError.unknownError(error))
            }
        }
    }

    private static func setNonBlocking(_ fileDescriptor: Int32) {
        let flags = fcntl(fileDescriptor, F_GETFL)
        guard flags != -1 else { return }
        _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
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
