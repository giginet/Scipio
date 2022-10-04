import Foundation
import XCTest
@testable import ScipioKit
import Logging
import TSCBasic

private let fixturePath = URL(fileURLWithPath: #file)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources")
    .appendingPathComponent("Fixtures")
private let testPackagePath = fixturePath.appendingPathComponent("TestingPackage")

final class PrepareTests: XCTestCase {
    private let fileManager: FileManager = .default

    override class func setUp() {
        LoggingSystem.bootstrap { _ in SwiftLogNoOpLogHandler() }

        super.setUp()
    }

    func testBuildXCFramework() async throws {
        let frameworkOutputDir = AbsolutePath(NSTemporaryDirectory()).appending(component: "XCFrameworks")
        try fileManager.createDirectory(at: frameworkOutputDir.asURL, withIntermediateDirectories: true)

        let runner = Runner(
            mode: .prepareDependencies,
            options: .init(
                buildConfiguration: .release,
                isSimulatorSupported: false,
                isDebugSymbolsEmbedded: false,
                cacheMode: .disabled,
                verbose: true))
        do {
            try await runner.run(packageDirectory: testPackagePath,
                                 frameworkOutputDir: .custom(frameworkOutputDir.asURL))
        } catch {
            XCTFail("Build should be succeeded.")
        }

        ["Logging"].forEach { library in
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
            try self.fileManager.removeItem(at: frameworkOutputDir.asURL)
        }
    }

    func testCacheIsValid() async throws {
        let frameworkOutputDir = AbsolutePath(NSTemporaryDirectory()).appending(component: "XCFrameworks")
        try fileManager.createDirectory(at: frameworkOutputDir.asURL, withIntermediateDirectories: true)

        let rootPackage = try Package(packageDirectory: AbsolutePath(testPackagePath.path))
        let cacheSystem = CacheSystem(rootPackage: rootPackage,
                                      buildOptions: .init(buildConfiguration: .release,
                                                          isSimulatorSupported: false,
                                                          isDebugSymbolsEmbedded: false,
                                                          sdks: [.iOS]),
                                      outputDirectory: frameworkOutputDir,
                                      storage: nil)
        let packages = rootPackage.graph.packages
            .filter { $0.manifest.displayName != rootPackage.manifest.displayName }

        for subPackage in packages {
            for target in subPackage.targets {
                try await cacheSystem.generateVersionFile(subPackage: subPackage, target: target)
                // generate dummy directory
                try fileManager.createDirectory(at: frameworkOutputDir.appending(component: "\(target.name).xcframework").asURL, withIntermediateDirectories: true)
            }
        }
        let versionFile2 = frameworkOutputDir.appending(component: ".Logging.version")
        XCTAssertTrue(fileManager.fileExists(atPath: versionFile2.pathString))

        let runner = Runner(
            mode: .prepareDependencies,
            options: .init(
                buildConfiguration: .release,
                isSimulatorSupported: false,
                isDebugSymbolsEmbedded: false,
                cacheMode: .storage(nil),
                verbose: false)
        )
        do {
            try await runner.run(packageDirectory: testPackagePath,
                                 frameworkOutputDir: .custom(frameworkOutputDir.asURL))
        } catch {
            XCTFail("Build should be succeeded.")
        }

        ["Logging"].forEach { library in
            let xcFramework = frameworkOutputDir.appending(components: "\(library).xcframework", "Info.plist")
            let versionFile = frameworkOutputDir.appending(component: ".\(library).version")
            XCTAssertFalse(fileManager.fileExists(atPath: xcFramework.pathString),
                           "Should skip to build \(library).xcramework")
            XCTAssertTrue(fileManager.fileExists(atPath: versionFile.pathString),
                          "Should create .\(library).version")
        }

        addTeardownBlock {
            try self.fileManager.removeItem(at: testPackagePath.appendingPathComponent(".build"))
            try self.fileManager.removeItem(at: frameworkOutputDir.asURL)
        }
    }
}
