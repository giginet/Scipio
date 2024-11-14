import Foundation
import XCTest
@testable import ScipioKit
import Logging

private let fixturePath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources")
    .appendingPathComponent("Fixtures")
private let testPackagePath = fixturePath.appendingPathComponent("E2ETestPackage")
private let binaryPackagePath = fixturePath.appendingPathComponent("BinaryPackage")
private let resourcePackagePath = fixturePath.appendingPathComponent("ResourcePackage")
private let usingBinaryPackagePath = fixturePath.appendingPathComponent("UsingBinaryPackage")
private let clangPackagePath = fixturePath.appendingPathComponent("ClangPackage")
private let clangPackageWithSymbolicLinkHeadersPath = fixturePath.appendingPathComponent("ClangPackageWithSymbolicLinkHeaders")
private let clangPackageWithCustomModuleMapPath = fixturePath.appendingPathComponent("ClangPackageWithCustomModuleMap")
private let clangPackageWithUmbrellaDirectoryPath = fixturePath.appendingPathComponent("ClangPackageWithUmbrellaDirectory")

private struct InfoPlist: Decodable {
    var bundleVersion: String
    var bundleShortVersionString: String
    var bundleExecutable: String

    enum CodingKeys: String, CodingKey {
        case bundleVersion = "CFBundleVersion"
        case bundleShortVersionString = "CFBundleShortVersionString"
        case bundleExecutable = "CFBundleExecutable"
    }
}

final class RunnerTests: XCTestCase {
    private let fileManager: FileManager = .default
    lazy var tempDir = fileManager.temporaryDirectory
    lazy var frameworkOutputDir = tempDir.appendingPathComponent("XCFrameworks")

    private let plistDecoder: PropertyListDecoder = .init()

    override static func setUp() {
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
                baseBuildOptions: .init(isSimulatorSupported: false, enableLibraryEvolution: true),
                shouldOnlyUseVersionsFromResolvedFile: true
            )
        )
        do {
            try await runner.run(packageDirectory: testPackagePath,
                                 frameworkOutputDir: .custom(frameworkOutputDir))
        } catch {
            XCTFail("Build should be succeeded. \(error.localizedDescription)")
        }

        for library in ["ScipioTesting"] {
            let xcFramework = frameworkOutputDir.appendingPathComponent("\(library).xcframework")
            let simulatorFramework = xcFramework.appendingPathComponent("ios-arm64_x86_64-simulator/\(library).framework")
            let deviceFramework = xcFramework.appendingPathComponent("ios-arm64/\(library).framework")

            XCTAssertTrue(
                fileManager.fileExists(atPath: deviceFramework.appendingPathComponent("Headers/\(library)-Swift.h").path),
                "Should exist a bridging header"
            )

            XCTAssertTrue(
                fileManager.fileExists(atPath: deviceFramework.appendingPathComponent("Modules/module.modulemap").path),
                "Should exist a modulemap"
            )

            let expectedSwiftInterface = deviceFramework.appendingPathComponent("Modules/\(library).swiftmodule/arm64-apple-ios.swiftinterface")
            XCTAssertTrue(
                fileManager.fileExists(atPath: expectedSwiftInterface.path),
                "Should exist a swiftinterface"
            )

            let frameworkType = try await detectFrameworkType(of: deviceFramework.appendingPathComponent(library))
            XCTAssertEqual(
                frameworkType,
                .dynamic,
                "Binary should be a dynamic library"
            )

            let infoPlistPath = deviceFramework.appendingPathComponent("Info.plist")
            let infoPlistData = try XCTUnwrap(
                fileManager.contents(atPath: infoPlistPath.path),
                "Info.plist should be exist"
            )

            let infoPlist = try plistDecoder.decode(InfoPlist.self, from: infoPlistData)
            XCTAssertEqual(infoPlist.bundleExecutable, library)
            XCTAssertEqual(infoPlist.bundleVersion, "1")
            XCTAssertEqual(infoPlist.bundleShortVersionString, "1.0")

            XCTAssertFalse(fileManager.fileExists(atPath: simulatorFramework.path),
                           "Should not create Simulator framework")
        }
    }

    func testBuildClangPackage() async throws {
        let runner = Runner(
            mode: .createPackage,
            options: .init(
                baseBuildOptions: .init(isSimulatorSupported: false),
                shouldOnlyUseVersionsFromResolvedFile: true
            )
        )
        do {
            try await runner.run(packageDirectory: clangPackagePath,
                                 frameworkOutputDir: .custom(frameworkOutputDir))
        } catch {
            XCTFail("Build should be succeeded. \(error.localizedDescription)")
        }

        for library in ["some_lib"] {
            let xcFramework = frameworkOutputDir.appendingPathComponent("\(library).xcframework")
            let versionFile = frameworkOutputDir.appendingPathComponent(".\(library).version")
            let framework = xcFramework.appendingPathComponent("ios-arm64")
                .appendingPathComponent("\(library).framework")

            XCTAssertTrue(
                fileManager.fileExists(atPath: framework.appendingPathComponent("Headers/some_lib.h").path),
                "Should exist an umbrella header"
            )

            let moduleMapPath = framework.appendingPathComponent("Modules/module.modulemap").path
            XCTAssertTrue(
                fileManager.fileExists(atPath: moduleMapPath),
                "Should exist a modulemap"
            )
            let moduleMapContents = try XCTUnwrap(fileManager.contents(atPath: moduleMapPath).flatMap { String(decoding: $0, as: UTF8.self) })
            XCTAssertEqual(
                moduleMapContents,
                """
                framework module some_lib {
                    umbrella header "some_lib.h"
                    export *
                }
                """,
                "modulemap should be generated"
            )

            XCTAssertTrue(fileManager.fileExists(atPath: xcFramework.path),
                          "Should create \(library).xcframework")
            XCTAssertFalse(fileManager.fileExists(atPath: versionFile.path),
                           "Should not create .\(library).version in create mode")
        }
    }

    func testBuildClangPackageWithSymbolicLinkHeaders() async throws {
        let runner = Runner(
            mode: .createPackage,
            options: .init(
                baseBuildOptions: .init(isSimulatorSupported: false),
                shouldOnlyUseVersionsFromResolvedFile: true
            )
        )
        do {
            try await runner.run(packageDirectory: clangPackageWithSymbolicLinkHeadersPath,
                                 frameworkOutputDir: .custom(frameworkOutputDir))
        } catch {
            XCTFail("Build should be succeeded. \(error.localizedDescription)")
        }

        for library in ["some_lib"] {
            print(frameworkOutputDir)
            let xcFramework = frameworkOutputDir.appendingPathComponent("\(library).xcframework")
            let versionFile = frameworkOutputDir.appendingPathComponent(".\(library).version")
            let framework = xcFramework.appendingPathComponent("ios-arm64")
                .appendingPathComponent("\(library).framework")

            XCTAssertTrue(
                fileManager.fileExists(atPath: framework.appendingPathComponent("Headers/some_lib.h").path),
                "Should exist an umbrella header"
            )
            XCTAssertTrue(
                fileManager.fileExists(atPath: framework.appendingPathComponent("Headers/a.h").path),
                "Should exist a header from symbolic link"
            )
            XCTAssertTrue(
                fileManager.fileExists(atPath: framework.appendingPathComponent("Headers/b.h").path),
                "Should exist another header from symbolic link"
            )
            XCTAssertFalse(
                fileManager.fileExists(atPath: framework.appendingPathComponent("Headers/some_lib_dupe.h").path),
                "Should not exist a header from symbolic link which is duplicated to non-symbolic link one"
            )

            let moduleMapPath = framework.appendingPathComponent("Modules/module.modulemap").path
            XCTAssertTrue(
                fileManager.fileExists(atPath: moduleMapPath),
                "Should exist a modulemap"
            )
            let moduleMapContents = try XCTUnwrap(fileManager.contents(atPath: moduleMapPath).flatMap { String(decoding: $0, as: UTF8.self) })
            XCTAssertEqual(
                moduleMapContents,
                """
                framework module some_lib {
                    umbrella header "some_lib.h"
                    export *
                }
                """,
                "modulemap should be generated"
            )

            XCTAssertTrue(fileManager.fileExists(atPath: xcFramework.path),
                          "Should create \(library).xcframework")
            XCTAssertFalse(fileManager.fileExists(atPath: versionFile.path),
                           "Should not create .\(library).version in create mode")
        }
    }

    func testBuildClangPackageWithCustomModuleMap() async throws {
        let runner = Runner(
            mode: .createPackage,
            options: .init(
                baseBuildOptions: .init(isSimulatorSupported: false),
                shouldOnlyUseVersionsFromResolvedFile: true
            )
        )
        do {
            try await runner.run(packageDirectory: clangPackageWithCustomModuleMapPath,
                                 frameworkOutputDir: .custom(frameworkOutputDir))
        } catch {
            XCTFail("Build should be succeeded. \(error.localizedDescription)")
        }

        for library in ["ClangPackageWithCustomModuleMap"] {
            let xcFramework = frameworkOutputDir.appendingPathComponent("\(library).xcframework")
            let versionFile = frameworkOutputDir.appendingPathComponent(".\(library).version")
            let framework = xcFramework.appendingPathComponent("ios-arm64")
                .appendingPathComponent("\(library).framework")

            XCTAssertTrue(
                fileManager.fileExists(atPath: framework.appendingPathComponent("Headers/mycalc.h").path),
                "Should exist an umbrella header"
            )

            let moduleMapPath = framework.appendingPathComponent("Modules/module.modulemap").path
            XCTAssertTrue(
                fileManager.fileExists(atPath: moduleMapPath),
                "Should exist a modulemap"
            )
            let moduleMapContents = try XCTUnwrap(fileManager.contents(atPath: moduleMapPath).flatMap { String(decoding: $0, as: UTF8.self) })
            XCTAssertEqual(
                moduleMapContents,
                """
                framework module ClangPackageWithCustomModuleMap {
                  header "mycalc.h"
                }
                """,
                "modulemap should be converted for frameworks"
            )

            XCTAssertTrue(fileManager.fileExists(atPath: xcFramework.path),
                          "Should create \(library).xcframework")
            XCTAssertFalse(fileManager.fileExists(atPath: versionFile.path),
                           "Should not create .\(library).version in create mode")
        }
    }

    func testCacheIsValid() async throws {
        let descriptionPackage = try DescriptionPackage(
            packageDirectory: testPackagePath.absolutePath,
            mode: .prepareDependencies,
            onlyUseVersionsFromResolvedFile: false
        )
        let pinsStore = try descriptionPackage.workspace.pinsStore.load()
        let cacheSystem = CacheSystem(
            pinsStore: pinsStore,
            outputDirectory: frameworkOutputDir
        )
        let packages = descriptionPackage.graph.packages
            .filter { $0.manifest.displayName != descriptionPackage.manifest.displayName }

        let allTargets = packages
            .flatMap { package in
                package.modules.map { BuildProduct(package: package, target: $0) }
            }
            .map {
                CacheSystem.CacheTarget(buildProduct: $0, buildOptions: .default)
            }

        for product in allTargets {
            try await cacheSystem.generateVersionFile(for: product)
            // generate dummy directory
            try fileManager.createDirectory(
                at: frameworkOutputDir.appendingPathComponent(product.buildProduct.frameworkName),
                withIntermediateDirectories: true
            )
        }
        let versionFile2 = frameworkOutputDir.appendingPathComponent(".ScipioTesting.version")
        XCTAssertTrue(fileManager.fileExists(atPath: versionFile2.path))

        let runner = Runner(
            mode: .prepareDependencies,
            options: .init(
                baseBuildOptions: .init(enableLibraryEvolution: true),
                shouldOnlyUseVersionsFromResolvedFile: true,
                cachePolicies: [.project]
            )
        )
        do {
            try await runner.run(packageDirectory: testPackagePath,
                                 frameworkOutputDir: .custom(frameworkOutputDir))
        } catch {
            XCTFail("Build should be succeeded. \(error.localizedDescription)")
        }

        for library in ["ScipioTesting"] {
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

    func testLocalDiskCacheStorage() async throws {
        let storage = LocalDiskCacheStorage(baseURL: tempDir)
        let storageDir = tempDir.appendingPathComponent("Scipio")

        let runner = Runner(
            mode: .prepareDependencies,
            options: .init(
                shouldOnlyUseVersionsFromResolvedFile: true,
                cachePolicies: [
                    .init(storage: storage, actors: [.consumer, .producer]),
                ]
            )
        )
        do {
            try await runner.run(packageDirectory: testPackagePath,
                                 frameworkOutputDir: .custom(frameworkOutputDir))
        } catch {
            XCTFail("Build should be succeeded. \(error.localizedDescription)")
        }

        XCTAssertTrue(
            fileManager.fileExists(atPath: storageDir.appendingPathComponent("ScipioTesting").path),
            "The framework should be cached to the cache storage"
        )

        let outputFrameworkPath = frameworkOutputDir.appendingPathComponent("ScipioTesting.xcframework")
        try self.fileManager.removeItem(atPath: outputFrameworkPath.path)

        // Fetch from local storage
        do {
            try await runner.run(packageDirectory: testPackagePath,
                                 frameworkOutputDir: .custom(frameworkOutputDir))
        } catch {
            XCTFail("Build should be succeeded.")
        }

        XCTAssertTrue(
            fileManager.fileExists(atPath: outputFrameworkPath.path),
            "The framework should be restored from the cache storage"
        )

        try fileManager.removeItem(at: storageDir)
    }

    func testMultipleCachePolicies() async throws {
        let storage1CacheDir = tempDir.appending(path: "storage1", directoryHint: .isDirectory)
        let storage1 = LocalDiskCacheStorage(baseURL: storage1CacheDir)
        let storage1Dir = storage1CacheDir.appendingPathComponent("Scipio")

        let storage2CacheDir = tempDir.appending(path: "storage2", directoryHint: .isDirectory)
        let storage2 = LocalDiskCacheStorage(baseURL: storage2CacheDir)
        let storage2Dir = storage2CacheDir.appendingPathComponent("Scipio")

        let runner = Runner(
            mode: .prepareDependencies,
            options: .init(
                shouldOnlyUseVersionsFromResolvedFile: true,
                cachePolicies: [
                    .init(storage: storage1, actors: [.consumer, .producer]),
                    .init(storage: storage2, actors: [.consumer, .producer]),
                ]
            )
        )
        do {
            try await runner.run(packageDirectory: testPackagePath,
                                 frameworkOutputDir: .custom(frameworkOutputDir))
        } catch {
            XCTFail("Build should be succeeded. \(error.localizedDescription)")
        }

        // The cache are stored into 2 storages
        XCTAssertTrue(
            fileManager.fileExists(atPath: storage1Dir.appendingPathComponent("ScipioTesting").path),
            "The framework should be cached to the 1st cache storage"
        )
        XCTAssertTrue(
            fileManager.fileExists(atPath: storage2Dir.appendingPathComponent("ScipioTesting").path),
            "The framework should be cached to the 2nd cache storage as well"
        )

        let outputFrameworkPath = frameworkOutputDir.appendingPathComponent("ScipioTesting.xcframework")
        try self.fileManager.removeItem(atPath: outputFrameworkPath.path)

        // Remove the storage1's cache so storage2's cache should be used instead
        do {
            try fileManager.removeItem(at: storage1Dir.appendingPathComponent("ScipioTesting"))
            try await runner.run(packageDirectory: testPackagePath,
                                 frameworkOutputDir: .custom(frameworkOutputDir))
        } catch {
            XCTFail("Build should be succeeded.")
        }

        XCTAssertTrue(
            fileManager.fileExists(atPath: outputFrameworkPath.path),
            "The framework should be restored from the 2nd cache storage"
        )

        try fileManager.removeItem(at: storage1CacheDir)
        try fileManager.removeItem(at: storage2CacheDir)
    }

    func testExtractBinary() async throws {
        let runner = Runner(
            mode: .createPackage,
            options: .init(
                baseBuildOptions: .init(
                    buildConfiguration: .release,
                    isSimulatorSupported: false,
                    isDebugSymbolsEmbedded: false,
                    frameworkType: .dynamic
                ),
                shouldOnlyUseVersionsFromResolvedFile: true,
                cachePolicies: [.project],
                overwrite: false,
                verbose: false)
        )

        try await runner.run(packageDirectory: binaryPackagePath, frameworkOutputDir: .custom(frameworkOutputDir))

        let binaryPath = frameworkOutputDir.appendingPathComponent("SomeBinary.xcframework")
        XCTAssertTrue(
            fileManager.fileExists(atPath: binaryPath.path),
            "Binary frameworks should be copied."
        )

        try fileManager.removeItem(atPath: binaryPath.path)
    }

    func testPrepareBinary() async throws {
        let runner = Runner(
            mode: .prepareDependencies,
            options: .init(
                baseBuildOptions: .init(
                    buildConfiguration: .release,
                    isSimulatorSupported: false,
                    isDebugSymbolsEmbedded: false,
                    frameworkType: .dynamic
                ),
                shouldOnlyUseVersionsFromResolvedFile: true,
                cachePolicies: [.project],
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

        try fileManager.removeItem(atPath: binaryPath.path)
    }

    func testBinaryHasValidCache() async throws {
        // Generate VersionFile
        let descriptionPackage = try DescriptionPackage(
            packageDirectory: usingBinaryPackagePath.absolutePath,
            mode: .prepareDependencies,
            onlyUseVersionsFromResolvedFile: false
        )
        let pinsStore = try descriptionPackage.workspace.pinsStore.load()
        let cacheSystem = CacheSystem(
            pinsStore: pinsStore,
            outputDirectory: frameworkOutputDir
        )
        let packages = descriptionPackage.graph.packages
            .filter { $0.manifest.displayName != descriptionPackage.manifest.displayName }

        let allTargets = packages
            .flatMap { package in
                package.modules.map { BuildProduct(package: package, target: $0) }
            }
            .map {
                CacheSystem.CacheTarget(buildProduct: $0, buildOptions: .default)
            }

        for product in allTargets {
            try await cacheSystem.generateVersionFile(for: product)
            // generate dummy directory
            try fileManager.createDirectory(
                at: frameworkOutputDir.appendingPathComponent(product.buildProduct.frameworkName),
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
                baseBuildOptions: .init(
                    buildConfiguration: .release,
                    isSimulatorSupported: false,
                    isDebugSymbolsEmbedded: false,
                    frameworkType: .dynamic,
                    enableLibraryEvolution: true
                ),
                shouldOnlyUseVersionsFromResolvedFile: true,
                cachePolicies: [.project],
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

        try? fileManager.removeItem(atPath: binaryPath.path)
    }

    func testWithPlatformMatrix() async throws {
        let runner = Runner(
            mode: .prepareDependencies,
            options: .init(
                baseBuildOptions: .init(isSimulatorSupported: true),
                buildOptionsMatrix: [
                    "ScipioTesting": .init(
                        platforms: .specific([.iOS, .watchOS]),
                        isSimulatorSupported: true
                    ),
                ],
                shouldOnlyUseVersionsFromResolvedFile: true,
                cachePolicies: [.project],
                overwrite: false,
                verbose: false)
        )

        try await runner.run(packageDirectory: testPackagePath,
                             frameworkOutputDir: .custom(frameworkOutputDir))

        for library in ["ScipioTesting"] {
            let xcFramework = frameworkOutputDir.appendingPathComponent("\(library).xcframework")
            let versionFile = frameworkOutputDir.appendingPathComponent(".\(library).version")
            let contentsOfXCFramework = try XCTUnwrap(fileManager.contentsOfDirectory(atPath: xcFramework.path))
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
            mode: .createPackage,
            options: .init(
                baseBuildOptions: .init(
                    platforms: .specific([.iOS]),
                    isSimulatorSupported: true
                ),
                shouldOnlyUseVersionsFromResolvedFile: true,
                cachePolicies: []
            )
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

    func testMergeableLibrary() async throws {
        let runner = Runner(
            mode: .createPackage,
            options: .init(
                baseBuildOptions: .init(
                    platforms: .specific([.iOS]),
                    frameworkType: .mergeable
                ),
                shouldOnlyUseVersionsFromResolvedFile: true,
                cachePolicies: []
            )
        )

        try await runner.run(packageDirectory: testPackagePath,
                             frameworkOutputDir: .custom(frameworkOutputDir))

        let xcFramework = frameworkOutputDir.appendingPathComponent("TestingPackage.xcframework")

        let executor = ProcessExecutor()

        for arch in ["ios-arm64"] {
            let binaryPath = xcFramework
                .appendingPathComponent(arch)
                .appendingPathComponent("TestingPackage.framework")
                .appendingPathComponent("TestingPackage")
            XCTAssertTrue(
                fileManager.fileExists(atPath: binaryPath.path),
                "A framework for \(arch) should contain binary"
            )

            let executionResult = try await executor.execute("/usr/bin/otool", "-l", binaryPath.path())
            let loadCommands = try XCTUnwrap(executionResult.unwrapOutput())
            XCTAssertTrue(
                loadCommands.contains("LC_ATOM_INFO"),
                "A Mergeable Library should contain LC_ATOM_INFO segment"
            )
        }
    }

    func testWithExtraBuildParameters() async throws {
        let runner = Runner(
            mode: .prepareDependencies,
            options: .init(
                baseBuildOptions: .init(
                    isSimulatorSupported: false,
                    extraBuildParameters: [
                        "SWIFT_OPTIMIZATION_LEVEL": "-Osize",
                    ]
                ),
                shouldOnlyUseVersionsFromResolvedFile: true
            )
        )

        do {
            try await runner.run(packageDirectory: testPackagePath,
                                 frameworkOutputDir: .custom(frameworkOutputDir))
        } catch {
            XCTFail("Build should be succeeded. \(error.localizedDescription)")
        }

        for library in ["ScipioTesting"] {
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

    func testBuildXCFrameworkWithNoLibraryEvolution() async throws {
        let runner = Runner(
            mode: .prepareDependencies,
            options: .init(
                baseBuildOptions: .init(
                    isSimulatorSupported: false,
                    enableLibraryEvolution: false
                ),
                shouldOnlyUseVersionsFromResolvedFile: true
            )
        )
        do {
            try await runner.run(packageDirectory: testPackagePath,
                                 frameworkOutputDir: .custom(frameworkOutputDir))
        } catch {
            XCTFail("Build should be succeeded. \(error.localizedDescription)")
        }

        for library in ["ScipioTesting"] {
            let xcFramework = frameworkOutputDir.appendingPathComponent("\(library).xcframework")
            let versionFile = frameworkOutputDir.appendingPathComponent(".\(library).version")
            let simulatorFramework = xcFramework.appendingPathComponent("ios-arm64_x86_64-simulator/\(library).framework")
            let deviceFramework = xcFramework.appendingPathComponent("ios-arm64/\(library).framework")

            XCTAssertTrue(
                fileManager.fileExists(atPath: deviceFramework.appendingPathComponent("Headers/\(library)-Swift.h").path),
                "Should exist a bridging header"
            )

            XCTAssertTrue(
                fileManager.fileExists(atPath: deviceFramework.appendingPathComponent("Modules/module.modulemap").path),
                "Should exist a modulemap"
            )

            let expectedSwiftInterface = deviceFramework.appendingPathComponent("Modules/\(library).swiftmodule/arm64-apple-ios.swiftinterface")
            XCTAssertFalse(
                fileManager.fileExists(atPath: expectedSwiftInterface.path),
                "Should not exist a swiftinterface because emission is disabled"
            )

            XCTAssertTrue(fileManager.fileExists(atPath: xcFramework.path),
                          "Should create \(library).xcramework")
            XCTAssertTrue(fileManager.fileExists(atPath: versionFile.path),
                          "Should create .\(library).version")
            XCTAssertFalse(fileManager.fileExists(atPath: simulatorFramework.path),
                           "Should not create Simulator framework")
        }
    }

    func testGenerateModuleMapForUmbrellaDirectory() async throws {
        let runner = Runner(
            mode: .createPackage,
            options: .init(
                baseBuildOptions: .init(platforms: .specific([.iOS])),
                shouldOnlyUseVersionsFromResolvedFile: true
            )
        )
        do {
            try await runner.run(packageDirectory: clangPackageWithUmbrellaDirectoryPath,
                                 frameworkOutputDir: .custom(frameworkOutputDir))
        } catch {
            XCTFail("Build should be succeeded. \(error.localizedDescription)")
        }

        let xcFramework = frameworkOutputDir.appendingPathComponent("MyTarget.xcframework")

        let deviceFramework = xcFramework.appendingPathComponent("ios-arm64/MyTarget.framework")
        let moduleMapPath = deviceFramework
            .appendingPathComponent("Modules")
            .appendingPathComponent("module.modulemap")
        let headersDirPath = deviceFramework
            .appendingPathComponent("Headers")

        XCTAssertTrue(fileManager.fileExists(atPath: moduleMapPath.path))

        let generatedModuleMapData = try XCTUnwrap(fileManager.contents(atPath: moduleMapPath.path))
        let generatedModuleMapContents = String(decoding: generatedModuleMapData, as: UTF8.self)

        let expectedModuleMap = """
framework module MyTarget {
    header "a.h"
    header "add.h"
    header "b.h"
    header "c.h"
    header "my_target.h"
    export *
}
"""

        XCTAssertEqual(generatedModuleMapContents, expectedModuleMap, "A framework has a valid modulemap")

        let headers = try fileManager.contentsOfDirectory(atPath: headersDirPath.path)
        XCTAssertEqual(headers, [
            "a.h",
            "b.h",
            "add.h",
            "c.h",
            "my_target.h",
        ], "A framework contains all headers")
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

extension BuildOptions {
    fileprivate static let `default`: Self = .init(
        buildConfiguration: .release,
        isDebugSymbolsEmbedded: false,
        frameworkType: .dynamic,
        sdks: [.iOS],
        extraFlags: nil,
        extraBuildParameters: nil,
        enableLibraryEvolution: true,
        keepPublicHeadersStructure: false,
        customFrameworkModuleMapContents: nil
    )
}
