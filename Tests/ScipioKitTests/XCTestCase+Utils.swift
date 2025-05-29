import Foundation
@testable import ScipioKit
import Testing

func detectFrameworkType(of binaryPath: URL) async throws -> FrameworkType? {
    let executor = ProcessExecutor()
    let result = try await executor.execute("/usr/bin/file", binaryPath.path)
    let output = try #require(try result.unwrapOutput())
    if output.contains("current ar archive") {
        return .static
    } else if output.contains("dynamically linked shared library") {
        return .dynamic
    }
    return nil
}
