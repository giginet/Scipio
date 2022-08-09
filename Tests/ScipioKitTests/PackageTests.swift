import Foundation
@testable import ScipioKit
import XCTest

private let fixturePath = URL(fileURLWithPath: #file)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources")
    .appendingPathComponent("Fixtures")

final class PackageTests: XCTestCase {
    func testPackage() throws {
        let rootPath = fixturePath.appendingPathComponent("BasicPackage")
        let package = try XCTUnwrap(try Package(packageDirectory: rootPath))
        XCTAssertEqual(package.name, "BasicPackage")
    }
}
