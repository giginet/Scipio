import Foundation
import Testing
@testable import ScipioKit

@Suite("ProcessExecutorTests")
struct ProcessExecutorTests {

    struct ArgumentSet: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let arguments: [String]
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

    struct CommandTestCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let command: [String]
        let expectedOutput: String
        let checkStdErr: Bool
    }

    @Test("Execute commands successfully", arguments: [
        CommandTestCase(
            testDescription: "Echo command",
            command: ["/bin/echo", "hello", "world"],
            expectedOutput: "hello world"
        ),
        CommandTestCase(
            testDescription: "Standard error output",
            command: ["/bin/sh", "-c", "echo 'error message' >&2"],
            expectedOutput: "error message",
            checkStdErr: true
        ),
        CommandTestCase(
            testDescription: "Command with multiple arguments",
            command: ["/bin/sh", "-c", "echo $1 $2", "--", "arg1", "arg2"],
            expectedOutput: "arg1 arg2"
        ),
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

    struct StreamOutputTestCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let command: [String]
        let expectedOutputContains: String
    }

    @Test("Stream output functionality", arguments: [
        StreamOutputTestCase(
            testDescription: "Basic streaming test",
            command: ["/bin/echo", "streaming test"],
            expectedOutputContains: "streaming test"
        ),
        StreamOutputTestCase(
            testDescription: "Multi-line streaming test",
            command: ["/bin/sh", "-c", "echo 'line 1'; echo 'line 2'"],
            expectedOutputContains: "line"
        ),
    ])
    func streamOutput(testCase: StreamOutputTestCase) async throws {
        let (executor, collector) = createOutputStreamCollector()
        let result = try await executor.execute(testCase.command)

        #expect(result.exitStatus == .terminated(code: 0))

        // Verify that stream output was collected
        #expect(!collector.collectedOutput.isEmpty)
        let streamedData = Data(collector.collectedOutput.flatMap { $0 })
        let streamedString = try #require(String(data: streamedData, encoding: .utf8))
        #expect(streamedString.contains(testCase.expectedOutputContains))
    }

    // MARK: - Error Cases

    @Test("Executable not found error cases", arguments: [
        "Empty arguments array": [],
        "Empty executable string": [""],
        "Non-existent executable": ["/path/to/nonexistent/executable"],
    ])
    func executableNotFoundCases(testDescription: String, arguments: [String]) async throws {
        let executor = createExecutor()

        await #expect(throws: ProcessExecutorError.executableNotFound) {
            _ = try await executor.execute(arguments)
        }
    }

    struct ErrorTestCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let command: [String]
        let expectedErrorOutput: String?
    }

    @Test("Commands with non-zero exit code", arguments: [
        ErrorTestCase(
            testDescription: "Simple non-zero exit",
            command: ["/bin/sh", "-c", "exit 1"],
            expectedErrorOutput: nil
        ),
        ErrorTestCase(
            testDescription: "Non-zero exit with error output",
            command: ["/bin/sh", "-c", "echo 'error message' >&2; exit 1"],
            expectedErrorOutput: "error message"
        ),
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

    struct ErrorDecoderTestCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let command: [String]
        let expectedDecodedOutput: String
    }

    @Test("Verify error decoder is used for terminated errors", arguments: [
        ErrorDecoderTestCase(
            testDescription: "Simple error message",
            command: ["/bin/sh", "-c", "echo 'custom error' >&2; exit 1"],
            expectedDecodedOutput: "DECODED: custom error"
        ),
        ErrorDecoderTestCase(
            testDescription: "Multi-word error message",
            command: ["/bin/sh", "-c", "echo 'this is a custom error message' >&2; exit 1"],
            expectedDecodedOutput: "DECODED: this is a custom error message"
        ),
    ])
    func errorDecoderUsage(testCase: ErrorDecoderTestCase) async throws {
        let customDecoder = TestErrorDecoder()
        let executor = ProcessExecutor(errorDecoder: customDecoder)

        let thrownError = await #expect(throws: ProcessExecutorError.self) {
            _ = try await executor.execute(testCase.command)
        }

        // Verify it's a terminated error with the expected decoded output
        if case .terminated(let errorOutput) = thrownError {
            #expect(errorOutput == testCase.expectedDecodedOutput)
        } else {
            Issue.record("Expected terminated error, got: \(String(describing: thrownError))")
        }
    }

    // MARK: - Edge Cases

    enum EdgeCaseType: Sendable, CustomTestStringConvertible {
        case veryLongOutput(count: Int)
        case noOutput
        case binaryOutput

        var testDescription: String {
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

    struct EdgeCaseTestCase: @unchecked Sendable, CustomTestStringConvertible {
        let testDescription: String
        let type: EdgeCaseType
        let commandGenerator: @Sendable () -> [String]

        init(testDescription: String, type: EdgeCaseType, commandGenerator: @escaping @Sendable () -> [String]) {
            self.testDescription = testDescription
            self.type = type
            self.commandGenerator = commandGenerator
        }
    }

    @Test("Edge cases for output", arguments: [
        EdgeCaseTestCase(
            testDescription: "Very long output handling",
            type: .veryLongOutput(count: 10000),
            commandGenerator: {
                let longString = String(repeating: "a", count: 10000)
                return ["/bin/echo", longString]
            }
        ),
        EdgeCaseTestCase(
            testDescription: "Command with no output",
            type: .noOutput,
            commandGenerator: { ["/usr/bin/true"] }
        ),
        EdgeCaseTestCase(
            testDescription: "Command with binary output",
            type: .binaryOutput,
            commandGenerator: { ["/bin/sh", "-c", "printf '\\x00\\x01\\x02\\x03'"] }
        ),
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

    struct EnvironmentVariableTestCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let command: [String]
        let environment: [String: String]
        let expectedOutput: String
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
