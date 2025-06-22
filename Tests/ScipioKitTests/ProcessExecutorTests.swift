import Foundation
import Testing
@testable import ScipioKit

@Suite("ProcessExecutorTests")
struct ProcessExecutorTests {

    // MARK: - Test Helpers

    private func createExecutor() -> ProcessExecutor<StandardErrorOutputDecoder> {
        ProcessExecutor(decoder: StandardErrorOutputDecoder())
    }

    private func createOutputStreamCollector() -> (executor: ProcessExecutor<StandardErrorOutputDecoder>, outputCollector: OutputCollector) {
        let collector = OutputCollector()
        var executor = createExecutor()
        executor.streamOutput = collector.collect
        return (executor, collector)
    }

    // MARK: - Success Cases

    @Test("Execute echo command successfully")
    func executeEchoCommand() async throws {
        let executor = createExecutor()
        let result = try await executor.execute(["/bin/echo", "hello", "world"])

        #expect(result.arguments == ["/bin/echo", "hello", "world"])

        switch result.exitStatus {
        case .terminated(let code):
            #expect(code == 0)
        case .signalled:
            Issue.record("Process should not be signalled")
        }

        let output = try result.unwrapOutput()
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "hello world")
    }

    @Test("Execute command with standard error output")
    func executeCommandWithStderr() async throws {
        let executor = createExecutor()
        // Use a command that writes to stderr
        let result = try await executor.execute(["/bin/sh", "-c", "echo 'error message' >&2"])

        switch result.exitStatus {
        case .terminated(let code):
            #expect(code == 0)
        case .signalled:
            Issue.record("Process should not be signalled")
        }

        let stderrOutput = try result.unwrapStdErrOutput()
        #expect(stderrOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "error message")
    }

    @Test("Execute command with multiple arguments")
    func executeCommandWithMultipleArguments() async throws {
        let executor = createExecutor()
        let result = try await executor.execute(["/bin/sh", "-c", "echo $1 $2", "--", "arg1", "arg2"])

        switch result.exitStatus {
        case .terminated(let code):
            #expect(code == 0)
        case .signalled:
            Issue.record("Process should not be signalled")
        }

        let output = try result.unwrapOutput()
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "arg1 arg2")
    }

    @Test("Verify environment variables are captured")
    func environmentVariablesCaptured() async throws {
        let executor = createExecutor()
        let result = try await executor.execute(["/usr/bin/env"])

        #expect(!result.environment.isEmpty)
        // Check that some common environment variables exist
        #expect(result.environment["PATH"] != nil)
    }

    @Test("Stream output functionality")
    func streamOutput() async throws {
        let (executor, collector) = createOutputStreamCollector()
        let result = try await executor.execute(["/bin/echo", "streaming test"])

        switch result.exitStatus {
        case .terminated(let code):
            #expect(code == 0)
        case .signalled:
            Issue.record("Process should not be signalled")
        }

        // Verify that stream output was collected
        #expect(!collector.collectedOutput.isEmpty)
        let streamedData = Data(collector.collectedOutput.flatMap { $0 })
        let streamedString = String(data: streamedData, encoding: .utf8) ?? ""
        #expect(streamedString.contains("streaming test"))
    }
    
    // MARK: - Error Cases

    @Test("Empty arguments array throws executableNotFound")
    func emptyArgumentsArray() async throws {
        let executor = createExecutor()

        await #expect(throws: ProcessExecutorError.executableNotFound) {
            _ = try await executor.execute([])
        }
    }

    @Test("Empty executable string throws executableNotFound")
    func emptyExecutableString() async throws {
        let executor = createExecutor()

        await #expect(throws: ProcessExecutorError.executableNotFound) {
            _ = try await executor.execute([""])
        }
    }

    @Test("Non-existent executable throws executableNotFound")
    func nonExistentExecutable() async throws {
        let executor = createExecutor()

        await #expect(throws: ProcessExecutorError.executableNotFound) {
            _ = try await executor.execute(["/path/to/nonexistent/executable"])
        }
    }

    @Test("Command with non-zero exit code throws terminated error")
    func nonZeroExitCode() async throws {
        let executor = createExecutor()

        let thrownError = await #expect(throws: ProcessExecutorError.self) {
            _ = try await executor.execute(["/bin/sh", "-c", "exit 1"])
        }

        // Verify it's a terminated error
        if case .terminated = thrownError {
            // Expected
        } else {
            Issue.record("Expected terminated error, got: \(String(describing: thrownError))")
        }
    }

    @Test("Command with non-zero exit code and error output")
    func nonZeroExitCodeWithErrorOutput() async throws {
        let executor = createExecutor()

        let thrownError = await #expect(throws: ProcessExecutorError.self) {
            _ = try await executor.execute(["/bin/sh", "-c", "echo 'error message' >&2; exit 1"])
        }

        // Verify it's a terminated error with the expected error output
        if case .terminated(let errorOutput) = thrownError {
            #expect(errorOutput?.contains("error message") == true)
        } else {
            Issue.record("Expected terminated error, got: \(String(describing: thrownError))")
        }
    }

    @Test("Verify error decoder is used for terminated errors")
    func errorDecoderUsage() async throws {
        let customDecoder = TestErrorDecoder()
        let executor = ProcessExecutor(decoder: customDecoder)

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

    @Test("Very long output handling")
    func veryLongOutput() async throws {
        let executor = createExecutor()
        let longString = String(repeating: "a", count: 10000)
        let result = try await executor.execute(["/bin/echo", longString])

        switch result.exitStatus {
        case .terminated(let code):
            #expect(code == 0)
        case .signalled:
            Issue.record("Process should not be signalled")
        }

        let output = try result.unwrapOutput()
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines).count == 10000)
    }

    @Test("Command with no output")
    func commandWithNoOutput() async throws {
        let executor = createExecutor()
        let result = try await executor.execute(["/usr/bin/true"])

        switch result.exitStatus {
        case .terminated(let code):
            #expect(code == 0)
        case .signalled:
            Issue.record("Process should not be signalled")
        }

        let output = try result.unwrapOutput()
        #expect(output.isEmpty)
    }

    @Test("Command with binary output")
    func commandWithBinaryOutput() async throws {
        let executor = createExecutor()
        // Create a command that outputs binary data using printf with $'...' format
        let result = try await executor.execute(["/bin/sh", "-c", "printf '\\x00\\x01\\x02\\x03'"])

        switch result.exitStatus {
        case .terminated(let code):
            #expect(code == 0)
        case .signalled:
            Issue.record("Process should not be signalled")
        }

        switch result.output {
        case .success(let bytes):
            #expect(bytes == [0, 1, 2, 3])
        case .failure:
            Issue.record("Expected successful output")
        }
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
