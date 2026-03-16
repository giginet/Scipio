import Foundation
@testable @_spi(Internals) import ScipioKit

/// Detects the framework type (static or dynamic) of a binary.
enum FrameworkTypeDetector {
    /// Detects the framework type of a binary at the given path.
    static func detect(of binaryPath: URL) async throws -> FrameworkType? {
        let executor = ProcessExecutor()
        let result = try await executor.execute("/usr/bin/file", binaryPath.path)
        let output = try result.unwrapOutput()
        if output.contains("current ar archive") {
            return .static
        } else if output.contains("dynamically linked shared library") {
            return .dynamic
        }
        return nil
    }
}
