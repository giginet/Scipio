import Foundation
import XCTest
@testable import ScipioKit
import TSCBasic

private let fixturePath = URL(fileURLWithPath: #file)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources")
    .appendingPathComponent("Fixtures")
private let testPackagePath = fixturePath.appendingPathComponent("BasicPackage")

final class RunnerTests: XCTestCase {
    private let fileManager: FileManager = .default

    func testBuildXCFramework() async throws {
        let frameworkOutputDir = AbsolutePath(NSTemporaryDirectory()).appending(component: "XCFramework")
        try fileManager.createDirectory(at: frameworkOutputDir.asURL, withIntermediateDirectories: true)

        let runner = Runner(options: .init(
            buildConfiguration: .release,
            isSimulatorSupported: false,
            isDebugSymbolsEmbedded: false,
            isCacheEnabled: false,
            verbose: false))
        do {
            try await runner.run(packageDirectory: testPackagePath, frameworkOutputDir: frameworkOutputDir.asURL)
        } catch {
            XCTFail("Build should be succeeded.")
        }

        ["APNGKit", "Delegate"].forEach { library in
            let xcFramework = frameworkOutputDir.appending(component: "\(library).xcframework")
            let versionFile = frameworkOutputDir.appending(component: ".\(library).version")
            let simulatorFramework = xcFramework.appending(component: "ios-arm64_x86_64-simulator")
            XCTAssertTrue(fileManager.fileExists(atPath: xcFramework.pathString),
                          "Should create \(library).xcramework")
            XCTAssertTrue(fileManager.fileExists(atPath: versionFile.pathString),
                          "Should create .\(library).version")
            XCTAssertFalse(fileManager.fileExists(atPath: simulatorFramework.pathString),
                           "Should not create Simulator framework")
        }

        addTeardownBlock {
            try self.fileManager.removeItem(at: testPackagePath.appendingPathComponent(".build"))
        }
    }
}
