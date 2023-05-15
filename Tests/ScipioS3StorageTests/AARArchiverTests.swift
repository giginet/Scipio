import XCTest
@testable import ScipioS3Storage

final class AARArchiverTests: XCTestCase {
    private let fileManager = FileManager.default
    private var workspacePath: URL!

    override func setUp() async throws {
        workspacePath = fileManager.temporaryDirectory.appendingPathComponent("org.giginet.ScipioS3StorageTests")

        try fileManager.createDirectory(at: workspacePath, withIntermediateDirectories: true)

        addTeardownBlock {
            try? self.fileManager.removeItem(at: self.workspacePath)
        }
    }

    func testRoundTrips() throws {
        let xcframeworkPath = workspacePath.appendingPathComponent("\(UUID().uuidString).xcframework")
        try fileManager.createDirectory(at: xcframeworkPath, withIntermediateDirectories: true)

        let fileName = "hello.txt"
        let fileBody = UUID().uuidString

        fileManager.createFile(
            atPath: xcframeworkPath.appendingPathComponent(fileName).path,
            contents: fileBody.data(using: .utf8)
        )

        let archiver = try AARArchiver()
        let compressed = try XCTUnwrap(archiver.compress(xcframeworkPath))
        XCTAssertFalse(compressed.isEmpty, "Compression should be succeed")

        let extractedPath = workspacePath.appendingPathComponent("\(UUID().uuidString).xcframework")
        try archiver.extract(compressed, to: extractedPath)

        let fileContents = try XCTUnwrap(
            fileManager.contents(atPath: extractedPath.appendingPathComponent(fileName).path)
        )
        XCTAssertEqual(
            String(data: fileContents, encoding: .utf8),
            fileBody
        )

        addTeardownBlock {
            try? self.fileManager.removeItem(at: xcframeworkPath)
        }
    }
}
