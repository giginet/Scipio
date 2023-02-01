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
private let resourcePackagePath = fixturePath.appendingPathComponent("ResourcePackage")
private let usingBinaryPackagePath = fixturePath.appendingPathComponent("UsingBinaryPackage")

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
                overwrite: false,
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
        let descriptionPackage = try DescriptionPackage(packageDirectory: testPackagePath, mode: .prepareDependencies)
        let cacheSystem = CacheSystem(descriptionPackage: descriptionPackage,
                                      buildOptions: .init(buildConfiguration: .release,
                                                          isSimulatorSupported: false,
                                                          isDebugSymbolsEmbedded: false,
                                                          frameworkType: .dynamic,
                                                          sdks: [.iOS]),
                                      outputDirectory: frameworkOutputDir,
                                      storage: nil)
        let packages = descriptionPackage.graph.packages
            .filter { $0.manifest.displayName != descriptionPackage.manifest.displayName }

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
                overwrite: false,
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
                overwrite: false,
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
            mode: .createPackage(platforms: nil),
            options: .init(
                buildConfiguration: .release,
                isSimulatorSupported: false,
                isDebugSymbolsEmbedded: false,
                frameworkType: .dynamic,
                cacheMode: .project,
                overwrite: false,
                verbose: false)
        )

        try await runner.run(packageDirectory: binaryPackagePath, frameworkOutputDir: .custom(frameworkOutputDir))

        let binaryPath = frameworkOutputDir.appendingPathComponent("SomeBinary.xcframework")
        XCTAssertTrue(
            fileManager.fileExists(atPath: binaryPath.path),
            "Binary frameworks should be copied."
        )

        addTeardownBlock {
            try self.fileManager.removeItem(atPath: binaryPath.path)
        }
    }

    func testPrepareBinary() async throws {
        let runner = Runner(
            mode: .prepareDependencies,
            options: .init(
                buildConfiguration: .release,
                isSimulatorSupported: false,
                isDebugSymbolsEmbedded: false,
                frameworkType: .dynamic,
                cacheMode: .project,
                overwrite: false,
                verbose: false)
        )

        try await runner.run(packageDirectory: usingBinaryPackagePath, frameworkOutputDir: .custom(frameworkOutputDir))

        let binaryPath = frameworkOutputDir.appendingPathComponent("SomeBinary.xcframework")
        XCTAssertTrue(
            fileManager.fileExists(atPath: binaryPath.path),
            "Binary frameworks should be copied."
        )

        let versionFilePath = frameworkOutputDir.appendingPathComponent(".SomeBinary.version")
        XCTAssertTrue(
            fileManager.fileExists(atPath: versionFilePath.path),
            "Version files should be created"
        )

        addTeardownBlock {
            try self.fileManager.removeItem(atPath: binaryPath.path)
        }
    }

    func testBinaryHasValidCache() async throws {
        // Generate VersionFile
        let descriptionPackage = try DescriptionPackage(packageDirectory: usingBinaryPackagePath, mode: .prepareDependencies)
        let cacheSystem = CacheSystem(descriptionPackage: descriptionPackage,
                                      buildOptions: .init(buildConfiguration: .release,
                                                          isSimulatorSupported: false,
                                                          isDebugSymbolsEmbedded: false,
                                                          frameworkType: .dynamic,
                                                          sdks: [.iOS]),
                                      outputDirectory: frameworkOutputDir,
                                      storage: nil)
        let packages = descriptionPackage.graph.packages
            .filter { $0.manifest.displayName != descriptionPackage.manifest.displayName }

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
        let versionFile2 = frameworkOutputDir.appendingPathComponent(".SomeBinary.version")
        XCTAssertTrue(
            fileManager.fileExists(atPath: versionFile2.path),
            "VersionFile should be generated"
        )

        // Attempt to generate XCFrameworks
        let runner = Runner(
            mode: .prepareDependencies,
            options: .init(
                buildConfiguration: .release,
                isSimulatorSupported: false,
                isDebugSymbolsEmbedded: false,
                frameworkType: .dynamic,
                cacheMode: .project,
                overwrite: false,
                verbose: false)
        )

        try await runner.run(packageDirectory: usingBinaryPackagePath, frameworkOutputDir: .custom(frameworkOutputDir))

        let binaryPath = frameworkOutputDir.appendingPathComponent("SomeBinary.xcframework")
        XCTAssertTrue(
            fileManager.fileExists(atPath: binaryPath.path),
            "Binary frameworks should be copied."
        )

        // We generated an empty XCFramework directory to simulate cache is valid before.
        // So if runner doesn't create valid XCFrameworks, framework's contents are not exists
        let infoPlistPath = binaryPath.appendingPathComponent("Info.plist")
        XCTAssertFalse(
            fileManager.fileExists(atPath: infoPlistPath.path),
            "XCFramework should not be updated"
        )

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
                overwrite: false,
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

    func testWithResourcePackage() async throws {
        let runner = Runner(
            mode: .createPackage(platforms: nil),
            options: .init(
                buildConfiguration: .release,
                isSimulatorSupported: true,
                isDebugSymbolsEmbedded: false,
                frameworkType: .dynamic,
                cacheMode: .project,
                overwrite: false,
                verbose: false)
        )

        try await runner.run(packageDirectory: resourcePackagePath,
                             frameworkOutputDir: .custom(frameworkOutputDir))

        let xcFramework = frameworkOutputDir.appendingPathComponent("ResourcePackage.xcframework")
        for arch in ["ios-arm64", "ios-arm64_x86_64-simulator"] {
            let bundlePath = xcFramework
                .appendingPathComponent(arch)
                .appendingPathComponent("ResourcePackage.framework")
                .appendingPathComponent("ResourcePackage_ResourcePackage.bundle")
            XCTAssertTrue(
                fileManager.fileExists(atPath: bundlePath.path),
                "A framework for \(arch) should contain resource bundles"
            )
            XCTAssertTrue(
                fileManager.fileExists(atPath: bundlePath.appendingPathComponent("giginet.png").path),
                "Image files should be contained"
            )
            XCTAssertTrue(
                fileManager.fileExists(atPath: bundlePath.appendingPathComponent("AvatarView.nib").path),
                "XIB files should be contained"
            )

            let contents = try XCTUnwrap(try fileManager.contentsOfDirectory(atPath: bundlePath.path))
            XCTAssertTrue(
                Set(contents).isSuperset(of: ["giginet.png", "AvatarView.nib", "Info.plist"]),
                "The resource bundle should contain expected resources"
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
