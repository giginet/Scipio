import Foundation
import XCTest
import TSCBasic
@testable import ScipioKit

final class FrameworkModuleMapGeneratorTests: XCTestCase {
    func testExcludePaths() throws {
        let targetRootDir = try ScipioAbsolutePath(validating: "/tmp/path/to/package")

        let files = Set([
            targetRootDir.appending(component: "a.c"),
            targetRootDir.appending(component: "ignored.c"),
            targetRootDir.appending(components: ["include", "a.h"]),
            targetRootDir.appending(components: ["include", "ignored", "b.h"]),
            targetRootDir.appending(components: ["include", "not_ignored", "c.h"]),
        ])

        let excludeFilesPathString = Set([
            "./ignored.c",
            "./include/ignored/",
        ])
        let excludeFiles = Set(try excludeFilesPathString.compactMap { try RelativePath(validating: $0) })

        let result = FrameworkModuleMapGenerator.excludePaths(
            from: files,
            excludedFiles: excludeFiles,
            targetRoot: targetRootDir
        )
        XCTAssertEqual(result, Set([
            targetRootDir.appending(component: "a.c"),
            targetRootDir.appending(components: ["include", "a.h"]),
            targetRootDir.appending(components: ["include", "not_ignored", "c.h"]),
        ]), "The filtered paths are not included exclude files")
    }
}
