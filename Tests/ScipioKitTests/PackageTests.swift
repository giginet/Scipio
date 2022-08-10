import Foundation
@testable import ScipioKit
import XCTest
import TSCBasic

private let fixturePath = URL(fileURLWithPath: #file)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources")
    .appendingPathComponent("Fixtures")

final class PackageTests: XCTestCase {
    func testPackage() throws {
        let rootPath = fixturePath.appendingPathComponent("BasicPackage")
        let package = try XCTUnwrap(try Package(packageDirectory: AbsolutePath(rootPath.path)))
        XCTAssertEqual(package.name, "BasicPackage")

        let argumentParser = try XCTUnwrap(package.graph.packages.last)
        XCTAssertEqual(argumentParser.manifest.displayName, "swift-argument-parser")
    }
}
