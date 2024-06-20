import Foundation
@testable import ScipioKit
import struct TSCBasic.ProcessResult

final class StubbableExecutor: Executor {
    init(executeHook: @escaping (([String]) throws -> any ExecutorResult)) {
        self.executeHook = executeHook
    }

    let executeHook: (([String]) throws -> any ExecutorResult)
    private(set) var calledArguments: [[String]] = []

    var calledCount: Int {
        calledArguments.count
    }

    func execute(_ arguments: [String]) async throws -> any ExecutorResult {
        calledArguments.append(arguments)
        return try executeHook(arguments)
    }

    func outputStream(_: Data) {
        //
    }

    func errorOutputStream(_: Data) {
        //
    }
}

struct StubbableExecutorResult: ExecutorResult {
    var arguments: [String]
    var environment: [String: String]
    var exitStatus: TSCBasic.ProcessResult.ExitStatus
    var output: Result<[UInt8], any Error>
    var stderrOutput: Result<[UInt8], any Error>
}

extension StubbableExecutorResult {
    init(arguments: [String], success: String) {
        let data = success.data(using: .utf8)!
        let int: [UInt8] = data.withUnsafeBytes { pointer in
            pointer.reduce(into: []) { $0.append($1)  }
        }
        self.init(arguments: arguments,
                  environment: [:],
                  exitStatus: .terminated(code: 0),
                  output: .success(int),
                  stderrOutput: .success([]))
    }
}
