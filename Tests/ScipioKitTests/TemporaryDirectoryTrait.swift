import Foundation
import Testing

/// A test trait that provides a temporary directory for each test.
/// The directory is automatically created before and cleaned up after the test.
///
/// Usage:
/// ```swift
/// @Test(.temporaryDirectory)
/// func myTest() throws {
///     let tempDir = TemporaryDirectory.url
///     // Use tempDir...
/// }
/// ```
struct TemporaryDirectoryTrait: TestTrait, TestScoping {
    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing execute: @Sendable () async throws -> Void
    ) async throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
            .appending(components: "me.giginet.Scipio.Tests", UUID().uuidString)

        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? fileManager.removeItem(at: tempDir)
        }

        try await TemporaryDirectory.$url.withValue(tempDir) {
            try await execute()
        }
    }
}

/// Provides access to the current test's temporary directory via TaskLocal.
enum TemporaryDirectory {
    @TaskLocal static var url: URL = FileManager.default.temporaryDirectory
}

extension Trait where Self == TemporaryDirectoryTrait {
    /// A trait that provides a unique temporary directory for the test.
    static var temporaryDirectory: Self { Self() }
}
