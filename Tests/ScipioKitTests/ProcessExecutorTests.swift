import Foundation
import Testing
@testable import ScipioKit

@Suite("ProcessExecutorTests")
struct ProcessExecutorTests {
    
    struct ArgumentSet: Sendable {
        let testName: String
        let arguments: [String]
        
        init(testName: String, arguments: [String]) {
            self.testName = testName
            self.arguments = arguments
        }
    }

    // MARK: - Test Helpers

    private func createExecutor() -> ProcessExecutor<StandardErrorOutputDecoder> {
        ProcessExecutor(errorDecoder: StandardErrorOutputDecoder())
    }

    private func createOutputStreamCollector() -> (executor: ProcessExecutor<StandardErrorOutputDecoder>, outputCollector: OutputCollector) {
        let collector = OutputCollector()
        var executor = createExecutor()
        executor.streamOutput = collector.collect
        return (executor, collector)
    }

    // MARK: - Success Cases

    struct CommandTestCase: Sendable, CustomStringConvertible {
        let testName: String
        let command: [String]
        let expectedOutput: String
        let checkStdErr: Bool
        
        var description: String {
            return "Command: \(command.joined(separator: " ")) - Expected Output: \(expectedOutput)\(checkStdErr ? " (stderr)" : "")"
        }
        
        init(testName: String, command: [String], expectedOutput: String, checkStdErr: Bool = false) {
            self.testName = testName
            self.command = command
            self.expectedOutput = expectedOutput
            self.checkStdErr = checkStdErr
        }
    }
    
    @Test("Execute commands successfully", arguments: [
        CommandTestCase(
            testName: "Echo command", 
            command: ["/bin/echo", "hello", "world"], 
            expectedOutput: "hello world"
        ),
        CommandTestCase(
            testName: "Standard error output", 
            command: ["/bin/sh", "-c", "echo 'error message' >&2"], 
            expectedOutput: "error message", 
            checkStdErr: true
        ),
        CommandTestCase(
            testName: "Command with multiple arguments", 
            command: ["/bin/sh", "-c", "echo $1 $2", "--", "arg1", "arg2"], 
            expectedOutput: "arg1 arg2"
        )
    ])
    func executeCommandsSuccessfully(testCase: CommandTestCase) async throws {
        let executor = createExecutor()
        let result = try await executor.execute(testCase.command)

        #expect(result.arguments == testCase.command)
        #expect(result.exitStatus == .terminated(code: 0))

        let output: String
        if testCase.checkStdErr {
            output = try result.unwrapStdErrOutput()
        } else {
            output = try result.unwrapOutput()
        }
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == testCase.expectedOutput)
    }

    @Test("Stream output functionality")
    func streamOutput() async throws {
        let (executor, collector) = createOutputStreamCollector()
        let result = try await executor.execute(["/bin/echo", "streaming test"])

        #expect(result.exitStatus == .terminated(code: 0))

        // Verify that stream output was collected
        #expect(!collector.collectedOutput.isEmpty)
        let streamedData = Data(collector.collectedOutput.flatMap { $0 })
        let streamedString = try #require(String(data: streamedData, encoding: .utf8))
        #expect(streamedString.contains("streaming test"))
    }

    // MARK: - Error Cases

    @Test("Executable not found error cases", arguments: [
        "Empty arguments array": [],
        "Empty executable string": [""],
        "Non-existent executable": ["/path/to/nonexistent/executable"]
    ])
    func executableNotFoundCases(testName: String, arguments: [String]) async throws {
        let executor = createExecutor()

        await #expect(throws: ProcessExecutorError.executableNotFound) {
            _ = try await executor.execute(arguments)
        }
    }

    struct ErrorTestCase: Sendable, CustomStringConvertible {
        let testName: String
        let command: [String]
        let expectedErrorOutput: String?
        
        var description: String {
            return "Command: \(command.joined(separator: " "))\(expectedErrorOutput != nil ? " - Expected Error: \(expectedErrorOutput!)" : "")"
        }
        
        init(testName: String, command: [String], expectedErrorOutput: String? = nil) {
            self.testName = testName
            self.command = command
            self.expectedErrorOutput = expectedErrorOutput
        }
    }
    
    @Test("Commands with non-zero exit code", arguments: [
        ErrorTestCase(
            testName: "Simple non-zero exit", 
            command: ["/bin/sh", "-c", "exit 1"]
        ),
        ErrorTestCase(
            testName: "Non-zero exit with error output", 
            command: ["/bin/sh", "-c", "echo 'error message' >&2; exit 1"], 
            expectedErrorOutput: "error message"
        )
    ])
    func nonZeroExitCodeCases(testCase: ErrorTestCase) async throws {
        let executor = createExecutor()

        let thrownError = await #expect(throws: ProcessExecutorError.self) {
            _ = try await executor.execute(testCase.command)
        }

        // Verify it's a terminated error with the expected error output if any
        if case .terminated(let errorOutput) = thrownError {
            if let expectedOutput = testCase.expectedErrorOutput {
                #expect(errorOutput?.contains(expectedOutput) == true)
            }
        } else {
            Issue.record("Expected terminated error, got: \(String(describing: thrownError))")
        }
    }

    @Test("Verify error decoder is used for terminated errors")
    func errorDecoderUsage() async throws {
        let customDecoder = TestErrorDecoder()
        let executor = ProcessExecutor(errorDecoder: customDecoder)

        let thrownError = await #expect(throws: ProcessExecutorError.self) {
            _ = try await executor.execute(["/bin/sh", "-c", "echo 'custom error' >&2; exit 1"])
        }

        // Verify it's a terminated error with the expected decoded output
        if case .terminated(let errorOutput) = thrownError {
            #expect(errorOutput == "DECODED: custom error")
        } else {
            Issue.record("Expected terminated error, got: \(String(describing: thrownError))")
        }
    }

    // MARK: - Edge Cases

    enum EdgeCaseType: Sendable, CustomStringConvertible {
        case veryLongOutput(count: Int)
        case noOutput
        case binaryOutput
        
        var description: String {
            switch self {
            case .veryLongOutput(let count):
                return "veryLongOutput(count: \(count))"
            case .noOutput:
                return "noOutput"
            case .binaryOutput:
                return "binaryOutput"
            }
        }
    }
    
    struct EdgeCaseTestCase: @unchecked Sendable, CustomStringConvertible {
        let testName: String
        let type: EdgeCaseType
        let commandGenerator: @Sendable () -> [String]
        
        var description: String {
            let cmd = commandGenerator()
            return "Type: \(type) - Command: \(cmd.joined(separator: " "))"
        }
        
        init(testName: String, type: EdgeCaseType, commandGenerator: @escaping @Sendable () -> [String]) {
            self.testName = testName
            self.type = type
            self.commandGenerator = commandGenerator
        }
    }
    
    @Test("Edge cases for output", arguments: [
        EdgeCaseTestCase(
            testName: "Very long output handling",
            type: .veryLongOutput(count: 10000),
            commandGenerator: { 
                let longString = String(repeating: "a", count: 10000)
                return ["/bin/echo", longString]
            }
        ),
        EdgeCaseTestCase(
            testName: "Command with no output",
            type: .noOutput,
            commandGenerator: { ["/usr/bin/true"] }
        ),
        EdgeCaseTestCase(
            testName: "Command with binary output",
            type: .binaryOutput,
            commandGenerator: { ["/bin/sh", "-c", "printf '\\x00\\x01\\x02\\x03'"] }
        )
    ])
    func edgeCases(testCase: EdgeCaseTestCase) async throws {
        let executor = createExecutor()
        let command = testCase.commandGenerator()
        let result = try await executor.execute(command)

        #expect(result.exitStatus == .terminated(code: 0))

        switch testCase.type {
        case .veryLongOutput(let count):
            let output = try result.unwrapOutput()
            #expect(output.trimmingCharacters(in: .whitespacesAndNewlines).count == count)
        
        case .noOutput:
            let output = try result.unwrapOutput()
            #expect(output.isEmpty)
            
        case .binaryOutput:
            switch result.output {
            case .success(let bytes):
                #expect(bytes == [0, 1, 2, 3])
            case .failure:
                Issue.record("Expected successful output")
            }
        }
    }
    
    @Test("Execute command with environment variables")
    func executeCommandWithEnvironmentVariables() async throws {
        let executor = createExecutor()
        let process = try await executor.prepareProcess(["/bin/sh", "-c", "echo $TEST"])
        process.environment = ["TEST": "environment_variable_works"]
        
        let result = try await executor.run(process: process)
        
        #expect(result.exitStatus == .terminated(code: 0))
        
        let output = try result.unwrapOutput()
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "environment_variable_works")
    }
}

// MARK: - Test Helper Classes

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _collectedOutput: [[UInt8]] = []

    var collectedOutput: [[UInt8]] {
        lock.withLock { _collectedOutput }
    }

    func collect(_ bytes: [UInt8]) {
        lock.withLock {
            _collectedOutput.append(bytes)
        }
    }
}

private struct TestErrorDecoder: ErrorDecoder {
    func decode(_ result: ExecutorResult) throws -> String? {
        let stderr = try result.unwrapStdErrOutput()
        return "DECODED: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

// MARK: - Equatable Conformance for Testing

extension ProcessExecutorError: Equatable {
    public static func == (lhs: ProcessExecutorError, rhs: ProcessExecutorError) -> Bool {
        switch (lhs, rhs) {
        case (.executableNotFound, .executableNotFound):
            return true
        case (.terminated(let lhsOutput), .terminated(let rhsOutput)):
            return lhsOutput == rhsOutput
        case (.signalled(let lhsSignal), .signalled(let rhsSignal)):
            return lhsSignal == rhsSignal
        case (.unknownError(let lhsError), .unknownError(let rhsError)):
            return lhsError.localizedDescription == rhsError.localizedDescription
        default:
            return false
        }
    }
}
