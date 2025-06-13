import Foundation

protocol Executor {
    @discardableResult
    func execute(_ arguments: [String]) async throws -> ExecutorResult
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

struct ProcessResult: ExecutorResult {
    enum ExitStatus {
        case terminated(code: Int32)
        case signalled(signal: Int32)
    }
    
    let arguments: [String]
    let environment: [String: String]
    let exitStatus: ExitStatus
    let output: Result<[UInt8], Swift.Error>
    let stderrOutput: Result<[UInt8], Swift.Error>
    
    init(
        arguments: [String],
        environment: [String: String],
        exitStatus: ExitStatus,
        output: Result<[UInt8], Swift.Error>,
        stderrOutput: Result<[UInt8], Swift.Error>
    ) {
        self.arguments = arguments
        self.environment = environment
        self.exitStatus = exitStatus
        self.output = output
        self.stderrOutput = stderrOutput
    }
}

enum ProcessExecutorError: LocalizedError {
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


struct ProcessExecutor<Decoder: ErrorDecoder>: Executor {
    private let decoder: Decoder
    init(decoder: Decoder = StandardErrorOutputDecoder()) {
        self.decoder = decoder
    }

    var streamOutput: (([UInt8]) -> Void)?
    var collectsOutput: Bool = true

    func execute(_ arguments: [String]) async throws -> ExecutorResult {
        logger.debug("\(arguments.joined(separator: " "))")

        guard let executable = arguments.first else {
            throw ProcessExecutorError.unknownError(NSError(domain: "ProcessExecutor", code: -1, userInfo: [NSLocalizedDescriptionKey: "No executable provided"]))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        // Set up reading from pipes
        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        
        do {
            try process.run()
        } catch {
            throw ProcessExecutorError.unknownError(error)
        }
        
        // Use async continuation to wait for process completion
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }
        
        // Read output data
        let outputData = outputHandle.readDataToEndOfFile()
        let outputBuffer = [UInt8](outputData)
        
        // Call stream handler if available
        if let streamHandler = streamOutput, !outputBuffer.isEmpty {
            streamHandler(outputBuffer)
        }
        
        // Read error data
        let errorData = errorHandle.readDataToEndOfFile()
        let errorBuffer = [UInt8](errorData)
        
        let exitStatus: ProcessResult.ExitStatus
        if process.terminationReason == .exit {
            exitStatus = .terminated(code: process.terminationStatus)
        } else {
            exitStatus = .signalled(signal: process.terminationStatus)
        }
        
        let result = ProcessResult(
            arguments: arguments,
            environment: process.environment ?? ProcessInfo.processInfo.environment,
            exitStatus: exitStatus,
            output: .success(outputBuffer),
            stderrOutput: .success(errorBuffer)
        )
        
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
    func decode(_ result: ExecutorResult) throws -> String? {
        try result.unwrapStdErrOutput()
    }
}

struct StandardOutputDecoder: ErrorDecoder {
    func decode(_ result: ExecutorResult) throws -> String? {
        try result.unwrapOutput()
    }
}
