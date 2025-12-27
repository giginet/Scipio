import Foundation
@testable @_spi(Internals) import ScipioKit
import XCTest

extension XCTestCase {
    func detectFrameworkType(of binaryPath: URL) async throws -> FrameworkType? {
        let executor = ProcessExecutor()
        let result = try await executor.execute("/usr/bin/file", binaryPath.path)
        let output = try XCTUnwrap(try result.unwrapOutput())
        if output.contains("current ar archive") {
            return .static
        } else if output.contains("dynamically linked shared library") {
            return .dynamic
        }
        return nil
    }
}
