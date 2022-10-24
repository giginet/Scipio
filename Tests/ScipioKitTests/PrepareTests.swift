import Foundation
import XCTest
@testable import ScipioKit
import Logging

private let fixturePath = URL(fileURLWithPath: #file)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources")
    .appendingPathComponent("Fixtures")
private let testPackagePath = fixturePath.appendingPathComponent("E2ETestPackage")

final class PrepareTests: XCTestCase {
    private let fileManager: FileManager = .default

    override class func setUp() {
        LoggingSystem.bootstrap { _ in SwiftLogNoOpLogHandler() }

        super.setUp()
    }

    func testBuildXCFramework() async throws {
        let frameworkOutputDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("XCFrameworks")
        try fileManager.createDirectory(at: frameworkOutputDir, withIntermediateDirectories: true)

        let runner = Runner(
            mode: .prepareDependencies,
            options: .init(
                buildConfiguration: .release,
                isSimulatorSupported: false,
                isDebugSymbolsEmbedded: false,
                frameworkType: .dynamic,
                cacheMode: .disabled,
                verbose: true))
        do {
            try await runner.run(packageDirectory: testPackagePath,
                                 frameworkOutputDir: .custom(frameworkOutputDir))
        } catch {
            XCTFail("Build should be succeeded.")
        }

        ["ScipioTesting"].forEach { library in
            let xcFramework = frameworkOutputDir.appendingPathComponent("\(library).xcframework")
            let versionFile = frameworkOutputDir.appendingPathComponent(".\(library).version")
            let simulatorFramework = xcFramework.appendingPathComponent("ios-arm64_x86_64-simulator")
            XCTAssertTrue(fileManager.fileExists(atPath: xcFramework.path),
                          "Should create \(library).xcramework")
            XCTAssertTrue(fileManager.fileExists(atPath: versionFile.path),
                          "Should create .\(library).version")
            XCTAssertFalse(fileManager.fileExists(atPath: simulatorFramework.path),
                           "Should not create Simulator framework")
        }

        addTeardownBlock {
            try self.fileManager.removeItem(at: testPackagePath.appendingPathComponent(".build"))
            try self.fileManager.removeItem(at: frameworkOutputDir)
        }
    }

    func testCacheIsValid() async throws {
        let frameworkOutputDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("XCFrameworks")
        try fileManager.createDirectory(at: frameworkOutputDir, withIntermediateDirectories: true)

        let rootPackage = try Package(packageDirectory: testPackagePath)
        let cacheSystem = CacheSystem(rootPackage: rootPackage,
                                      buildOptions: .init(buildConfiguration: .release,
                                                          isSimulatorSupported: false,
                                                          isDebugSymbolsEmbedded: false,
                                                          frameworkType: .dynamic,
                                                          sdks: [.iOS]),
                                      outputDirectory: frameworkOutputDir,
                                      storage: nil)
        let packages = rootPackage.graph.packages
            .filter { $0.manifest.displayName != rootPackage.manifest.displayName }

        for subPackage in packages {
            for target in subPackage.targets {
                try await cacheSystem.generateVersionFile(subPackage: subPackage, target: target)
                // generate dummy directory
                try fileManager.createDirectory(
                    at: frameworkOutputDir.appendingPathComponent("\(target.name).xcframework"),
                    withIntermediateDirectories: true
                )
            }
        }
        let versionFile2 = frameworkOutputDir.appendingPathComponent(".ScipioTesting.version")
        XCTAssertTrue(fileManager.fileExists(atPath: versionFile2.path))

        let runner = Runner(
            mode: .prepareDependencies,
            options: .init(
                buildConfiguration: .release,
                isSimulatorSupported: false,
                isDebugSymbolsEmbedded: false,
                frameworkType: .dynamic,
                cacheMode: .project,
                verbose: false)
        )
        do {
            try await runner.run(packageDirectory: testPackagePath,
                                 frameworkOutputDir: .custom(frameworkOutputDir))
        } catch {
            XCTFail("Build should be succeeded.")
        }

        ["ScipioTesting"].forEach { library in
            let xcFramework = frameworkOutputDir
                .appendingPathComponent("\(library).xcframework")
                .appendingPathComponent("Info.plist")
            let versionFile = frameworkOutputDir.appendingPathComponent(".\(library).version")
            XCTAssertFalse(fileManager.fileExists(atPath: xcFramework.path),
                           "Should skip to build \(library).xcramework")
            XCTAssertTrue(fileManager.fileExists(atPath: versionFile.path),
                          "Should create .\(library).version")
        }

        addTeardownBlock {
            try self.fileManager.removeItem(at: testPackagePath.appendingPathComponent(".build"))
            try self.fileManager.removeItem(at: frameworkOutputDir)
        }
    }

    func testLocalStorage() async throws {
        let frameworkOutputDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("XCFrameworks")
        try fileManager.createDirectory(at: frameworkOutputDir, withIntermediateDirectories: true)

        let tempDir = fileManager.temporaryDirectory
        let storage = LocalCacheStorage(cacheDirectory: .custom(tempDir))
        let storageDir = tempDir.appendingPathComponent("Scipio")

        let runner = Runner(
            mode: .prepareDependencies,
            options: .init(
                buildConfiguration: .release,
                isSimulatorSupported: false,
                isDebugSymbolsEmbedded: false,
                frameworkType: .dynamic,
                cacheMode: .storage(storage),
                verbose: false)
        )
        do {
            try await runner.run(packageDirectory: testPackagePath,
                                 frameworkOutputDir: .custom(frameworkOutputDir))
        } catch {
            XCTFail("Build should be succeeded.")
        }

        XCTAssertTrue(fileManager.fileExists(atPath: storageDir.appendingPathComponent("ScipioTesting").path))

        let outputFrameworkPath = frameworkOutputDir.appendingPathComponent("ScipioTesting.xcframework")

        try self.fileManager.removeItem(atPath: outputFrameworkPath.path)

        // Fetch from local storage
        do {
            try await runner.run(packageDirectory: testPackagePath,
                                 frameworkOutputDir: .custom(frameworkOutputDir))
        } catch {
            XCTFail("Build should be succeeded.")
        }

        XCTAssertTrue(fileManager.fileExists(atPath: storageDir.appendingPathComponent("ScipioTesting").path))

        addTeardownBlock {
            try self.fileManager.removeItem(atPath: frameworkOutputDir.path)
            try self.fileManager.removeItem(atPath: storageDir.path)
        }
    }
}
