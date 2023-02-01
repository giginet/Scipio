import Foundation
@testable import ScipioKit
import XCTest

private let fixturePath = URL(fileURLWithPath: #file)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources")
    .appendingPathComponent("Fixtures")

final class PackageTests: XCTestCase {
    func testPackage() throws {
        let rootPath = fixturePath.appendingPathComponent("TestingPackage")
        let package = try XCTUnwrap(try DescriptionPackage(packageDirectory: rootPath))
        XCTAssertEqual(package.name, "TestingPackage")

        let packageNames = package.graph.packages.map(\.manifest.displayName)
        XCTAssertEqual(packageNames, ["TestingPackage", "swift-log"])
    }
}
