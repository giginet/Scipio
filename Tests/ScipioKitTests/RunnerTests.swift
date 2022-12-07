import Foundation
import XCTest
@testable import ScipioKit
import Logging

private let fixturePath = URL(fileURLWithPath: #file)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources")
    .appendingPathComponent("Fixtures")
private let testPackagePath = fixturePath.appendingPathComponent("E2ETestPackage")
private let binaryPackagePath = fixturePath.appendingPathComponent("BinaryPackage")

final class RunnerTests: XCTestCase {
    private let fileManager: FileManager = .default
    lazy var tempDir = fileManager.temporaryDirectory
    lazy var frameworkOutputDir = tempDir.appendingPathComponent("XCFrameworks")

    override class func setUp() {
        LoggingSystem.bootstrap { _ in SwiftLogNoOpLogHandler() }

        super.setUp()
    }

    override func setUpWithError() throws {
        try fileManager.createDirectory(at: frameworkOutputDir, withIntermediateDirectories: true)

        try super.setUpWithError()
    }

    func testBuildXCFramework() async throws {
        let runner = Runner(
            mode: .prepareDependencies,
            options: .init(
                buildConfiguration: .release,
                isSimulatorSupported: false,
                isDebugSymbolsEmbedded: false,
                frameworkType: .dynamic,
                cacheMode: .project,
                verbose: true))
        do {
            try await runner.run(packageDirectory: testPackagePath,
                                 frameworkOutputDir: .custom(frameworkOutputDir))
        } catch {
            XCTFail("Build should be succeeded. \(error.localizedDescription)")
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
    }

    func testCacheIsValid() async throws {
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

        let allProducts = packages.flatMap { package in
            package.targets.map { BuildProduct(package: package, target: $0) }
        }

        for product in allProducts {
            try await cacheSystem.generateVersionFile(for: product)
            // generate dummy directory
            try fileManager.createDirectory(
                at: frameworkOutputDir.appendingPathComponent("\(product.target.name).xcframework"),
                withIntermediateDirectories: true
            )
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
            XCTFail("Build should be succeeded. \(error.localizedDescription)")
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
    }

    func testLocalStorage() async throws {
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
            XCTFail("Build should be succeeded. \(error.localizedDescription)")
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
            try self.fileManager.removeItem(at: storageDir)
        }
    }

    func testExtractBinary() async throws {
        let runner = Runner(
            mode: .createPackage,
            options: .init(
                buildConfiguration: .release,
                isSimulatorSupported: false,
                isDebugSymbolsEmbedded: false,
                frameworkType: .dynamic,
                cacheMode: .disabled,
                verbose: false)
        )

        try await runner.run(packageDirectory: binaryPackagePath, frameworkOutputDir: .custom(frameworkOutputDir))

        let binaryPath = frameworkOutputDir.appendingPathComponent("SomeBinary.xcframework")
        XCTAssertTrue(fileManager.fileExists(atPath: binaryPath.path))

        addTeardownBlock {
            try self.fileManager.removeItem(atPath: binaryPath.path)
        }
    }

    func testWithPlatformMatrix() async throws {
        let runner = Runner(
            mode: .prepareDependencies,
            options: .init(
                buildConfiguration: .release,
                isSimulatorSupported: true,
                isDebugSymbolsEmbedded: false,
                frameworkType: .dynamic,
                cacheMode: .project,
                platformMatrix: ["ScipioTesting": [.iOS, .watchOS]],
                verbose: false)
        )

        try await runner.run(packageDirectory: testPackagePath,
                             frameworkOutputDir: .custom(frameworkOutputDir))

        ["ScipioTesting"].forEach { library in
            let xcFramework = frameworkOutputDir.appendingPathComponent("\(library).xcframework")
            let versionFile = frameworkOutputDir.appendingPathComponent(".\(library).version")
            let contentsOfXCFramework = try! XCTUnwrap(fileManager.contentsOfDirectory(atPath: xcFramework.path))
            XCTAssertTrue(fileManager.fileExists(atPath: xcFramework.path),
                          "Should create \(library).xcramework")
            XCTAssertTrue(fileManager.fileExists(atPath: versionFile.path),
                          "Should create .\(library).version")
            XCTAssertEqual(
                Set(contentsOfXCFramework),
                [
                    "Info.plist",
                    "watchos-arm64_arm64_32_armv7k",
                    "ios-arm64_x86_64-simulator",
                    "watchos-arm64_i386_x86_64-simulator",
                    "ios-arm64",
                ]
            )
        }
    }

    override func tearDownWithError() throws {
        try removeIfExist(at: testPackagePath.appendingPathComponent(".build"))
        try removeIfExist(at: frameworkOutputDir)
        try super.tearDownWithError()
    }

    private func removeIfExist(at path: URL) throws {
        if fileManager.fileExists(atPath: path.path) {
            try self.fileManager.removeItem(at: path)
        }
    }
}
