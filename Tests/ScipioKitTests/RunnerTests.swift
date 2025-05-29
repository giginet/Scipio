import Foundation
import Testing
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

@Suite(.serialized)
final class RunnerTests {
    private let fileManager: FileManager = .default
    private let tempDir = FileManager.default.temporaryDirectory
    private let frameworkOutputDir: URL
    private let plistDecoder: PropertyListDecoder = .init()

    init() throws {
        LoggingSystem.bootstrap { _ in SwiftLogNoOpLogHandler() }
        frameworkOutputDir = tempDir.appendingPathComponent("XCFrameworks")
        try fileManager.createDirectory(at: frameworkOutputDir, withIntermediateDirectories: true)
    }

    @Test func buildXCFramework() async throws {
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
            Issue.record("Build should be succeeded. \(error.localizedDescription)")
        }

        for library in ["ScipioTesting"] {
            let xcFramework = frameworkOutputDir.appendingPathComponent("\(library).xcframework")
            let simulatorFramework = xcFramework.appendingPathComponent("ios-arm64_x86_64-simulator/\(library).framework")
            let deviceFramework = xcFramework.appendingPathComponent("ios-arm64/\(library).framework")

            #expect(
                fileManager.fileExists(atPath: deviceFramework.appendingPathComponent("Headers/\(library)-Swift.h").path),
                "Should exist a bridging header"
            )

            #expect(
                fileManager.fileExists(atPath: deviceFramework.appendingPathComponent("Modules/module.modulemap").path),
                "Should exist a modulemap"
            )

            let expectedSwiftInterface = deviceFramework.appendingPathComponent("Modules/\(library).swiftmodule/arm64-apple-ios.swiftinterface")
            #expect(
                fileManager.fileExists(atPath: expectedSwiftInterface.path),
                "Should exist a swiftinterface"
            )

            let frameworkType = try await detectFrameworkType(of: deviceFramework.appendingPathComponent(library))
            #expect(
                frameworkType == .dynamic,
                "Binary should be a dynamic library"
            )

            let infoPlistPath = deviceFramework.appendingPathComponent("Info.plist")
            let infoPlistData = try #require(
                fileManager.contents(atPath: infoPlistPath.path),
                "Info.plist should be exist"
            )

            let infoPlist = try plistDecoder.decode(InfoPlist.self, from: infoPlistData)
            #expect(infoPlist.bundleExecutable == library)
            #expect(infoPlist.bundleVersion == "1")
            #expect(infoPlist.bundleShortVersionString == "1.0")

            #expect(!fileManager.fileExists(atPath: simulatorFramework.path),
                           "Should not create Simulator framework")
        }
    }

    @Test func buildClangPackage() async throws {
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
            Issue.record("Build should be succeeded. \(error.localizedDescription)")
        }

        for library in ["some_lib"] {
            let xcFramework = frameworkOutputDir.appendingPathComponent("\(library).xcframework")
            let versionFile = frameworkOutputDir.appendingPathComponent(".\(library).version")
            let framework = xcFramework.appendingPathComponent("ios-arm64")
                .appendingPathComponent("\(library).framework")

            #expect(
                fileManager.fileExists(atPath: framework.appendingPathComponent("Headers/some_lib.h").path),
                "Should exist an umbrella header"
            )

            let moduleMapPath = framework.appendingPathComponent("Modules/module.modulemap").path
            #expect(
                fileManager.fileExists(atPath: moduleMapPath),
                "Should exist a modulemap"
            )
            let moduleMapContents = try #require(fileManager.contents(atPath: moduleMapPath).flatMap { String(decoding: $0, as: UTF8.self) })
            #expect(
                moduleMapContents == """
                framework module some_lib {
                    umbrella header "some_lib.h"
                    export *
                }
                """,
                "modulemap should be generated"
            )

            #expect(fileManager.fileExists(atPath: xcFramework.path),
                          "Should create \(library).xcframework")
            #expect(!fileManager.fileExists(atPath: versionFile.path),
                           "Should not create .\(library).version in create mode")
        }
    }

    @Test func buildClangPackageWithSymbolicLinkHeaders() async throws {
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
            Issue.record("Build should be succeeded. \(error.localizedDescription)")
        }

        for library in ["some_lib"] {
            print(frameworkOutputDir)
            let xcFramework = frameworkOutputDir.appendingPathComponent("\(library).xcframework")
            let versionFile = frameworkOutputDir.appendingPathComponent(".\(library).version")
            let framework = xcFramework.appendingPathComponent("ios-arm64")
                .appendingPathComponent("\(library).framework")

            #expect(
                fileManager.fileExists(atPath: framework.appendingPathComponent("Headers/some_lib.h").path),
                "Should exist an umbrella header"
            )
            #expect(
                fileManager.fileExists(atPath: framework.appendingPathComponent("Headers/a.h").path),
                "Should exist a header from symbolic link"
            )
            #expect(
                fileManager.fileExists(atPath: framework.appendingPathComponent("Headers/b.h").path),
                "Should exist another header from symbolic link"
            )
            #expect(
                !fileManager.fileExists(atPath: framework.appendingPathComponent("Headers/some_lib_dupe.h").path),
                "Should not exist a header from symbolic link which is duplicated to non-symbolic link one"
            )

            let moduleMapPath = framework.appendingPathComponent("Modules/module.modulemap").path
            #expect(
                fileManager.fileExists(atPath: moduleMapPath),
                "Should exist a modulemap"
            )
            let moduleMapContents = try #require(fileManager.contents(atPath: moduleMapPath).flatMap { String(decoding: $0, as: UTF8.self) })
            #expect(
                moduleMapContents == """
                framework module some_lib {
                    umbrella header "some_lib.h"
                    export *
                }
                """,
                "modulemap should be generated"
            )

            #expect(fileManager.fileExists(atPath: xcFramework.path),
                          "Should create \(library).xcframework")
            #expect(!fileManager.fileExists(atPath: versionFile.path),
                           "Should not create .\(library).version in create mode")
        }
    }

    @Test func buildClangPackageWithCustomModuleMap() async throws {
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
            Issue.record("Build should be succeeded. \(error.localizedDescription)")
        }

        for library in ["ClangPackageWithCustomModuleMap"] {
            let xcFramework = frameworkOutputDir.appendingPathComponent("\(library).xcframework")
            let versionFile = frameworkOutputDir.appendingPathComponent(".\(library).version")
            let framework = xcFramework.appendingPathComponent("ios-arm64")
                .appendingPathComponent("\(library).framework")

            #expect(
                fileManager.fileExists(atPath: framework.appendingPathComponent("Headers/mycalc.h").path),
                "Should exist an umbrella header"
            )

            let moduleMapPath = framework.appendingPathComponent("Modules/module.modulemap").path
            #expect(
                fileManager.fileExists(atPath: moduleMapPath),
                "Should exist a modulemap"
            )
            let moduleMapContents = try #require(fileManager.contents(atPath: moduleMapPath).flatMap { String(decoding: $0, as: UTF8.self) })
            #expect(
                moduleMapContents == """
                framework module ClangPackageWithCustomModuleMap {
                  header "mycalc.h"
                }
                """,
                "modulemap should be converted for frameworks"
            )

            #expect(fileManager.fileExists(atPath: xcFramework.path),
                          "Should create \(library).xcframework")
            #expect(!fileManager.fileExists(atPath: versionFile.path),
                           "Should not create .\(library).version in create mode")
        }
    }

    @Test func cacheIsValid() async throws {
        let descriptionPackage = try await DescriptionPackage(
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
            .filter { $0.manifest.displayName != descriptionPackage.manifest.name }

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
        #expect(fileManager.fileExists(atPath: versionFile2.path))

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
            Issue.record("Build should be succeeded. \(error.localizedDescription)")
        }

        for library in ["ScipioTesting"] {
            let xcFramework = frameworkOutputDir
                .appendingPathComponent("\(library).xcframework")
                .appendingPathComponent("Info.plist")
            let versionFile = frameworkOutputDir.appendingPathComponent(".\(library).version")
            #expect(!fileManager.fileExists(atPath: xcFramework.path),
                           "Should skip to build \(library).xcramework")
            #expect(fileManager.fileExists(atPath: versionFile.path),
                          "Should create .\(library).version")
        }
    }

    @Test func localDiskCacheStorage() async throws {
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
            Issue.record("Build should be succeeded. \(error.localizedDescription)")
        }

        #expect(
            fileManager.fileExists(atPath: storageDir.appendingPathComponent("ScipioTesting").path),
            "The framework should be cached to the cache storage"
        )

        try self.fileManager.removeItem(atPath: frameworkOutputDir.path)

        // Fetch from local storage
        do {
            try await runner.run(packageDirectory: testPackagePath,
                                 frameworkOutputDir: .custom(frameworkOutputDir))
        } catch {
            Issue.record("Build should be succeeded.")
        }

        let outputFrameworkPath = frameworkOutputDir.appendingPathComponent("ScipioTesting.xcframework")
        let outputVersionFile = frameworkOutputDir.appendingPathComponent(".ScipioTesting.version")

        #expect(
            fileManager.fileExists(atPath: outputFrameworkPath.path),
            "The framework should be restored from the cache storage"
        )
        #expect(
            fileManager.fileExists(atPath: outputVersionFile.path),
            "The version file should exist when restored"
        )

        try fileManager.removeItem(at: storageDir)
    }

    @Test func multipleCachePolicies() async throws {
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
            Issue.record("Build should be succeeded. \(error.localizedDescription)")
        }

        // The cache are stored into 2 storages
        #expect(
            fileManager.fileExists(atPath: storage1Dir.appendingPathComponent("ScipioTesting").path),
            "The framework should be cached to the 1st cache storage"
        )
        #expect(
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
            Issue.record("Build should be succeeded.")
        }

        #expect(
            fileManager.fileExists(atPath: outputFrameworkPath.path),
            "The framework should be restored from the 2nd cache storage"
        )

        try fileManager.removeItem(at: storage1CacheDir)
        try fileManager.removeItem(at: storage2CacheDir)
    }

    @Test func extractBinary() async throws {
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
        #expect(
            fileManager.fileExists(atPath: binaryPath.path),
            "Binary frameworks should be copied."
        )

        try fileManager.removeItem(atPath: binaryPath.path)
    }

    @Test func prepareBinary() async throws {
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
        #expect(
            fileManager.fileExists(atPath: binaryPath.path),
            "Binary frameworks should be copied."
        )

        let versionFilePath = frameworkOutputDir.appendingPathComponent(".SomeBinary.version")
        #expect(
            fileManager.fileExists(atPath: versionFilePath.path),
            "Version files should be created"
        )

        try fileManager.removeItem(atPath: binaryPath.path)
    }

    @Test func binaryHasValidCache() async throws {
        // Generate VersionFile
        let descriptionPackage = try await DescriptionPackage(
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
            .filter { $0.manifest.displayName != descriptionPackage.manifest.name }

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
        #expect(
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
        #expect(
            fileManager.fileExists(atPath: binaryPath.path),
            "Binary frameworks should be copied."
        )

        // We generated an empty XCFramework directory to simulate cache is valid before.
        // So if runner doesn't create valid XCFrameworks, framework's contents are not exists
        let infoPlistPath = binaryPath.appendingPathComponent("Info.plist")
        #expect(
            !fileManager.fileExists(atPath: infoPlistPath.path),
            "XCFramework should not be updated"
        )

        try? fileManager.removeItem(atPath: binaryPath.path)
    }

    @Test func withPlatformMatrix() async throws {
        let runner = Runner(
            mode: .prepareDependencies,
            options: .init(
                baseBuildOptions: .init(
                    isSimulatorSupported: true,
                    extraBuildParameters: [
                        "EXCLUDED_ARCHS": "i386",
                    ]
                ),
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
            let contentsOfXCFramework = try #require(try fileManager.contentsOfDirectory(atPath: xcFramework.path))
            #expect(fileManager.fileExists(atPath: xcFramework.path),
                          "Should create \(library).xcramework")
            #expect(fileManager.fileExists(atPath: versionFile.path),
                          "Should create .\(library).version")
            #expect(
                Set(contentsOfXCFramework) == [
                    "Info.plist",
                    "watchos-arm64_arm64_32_armv7k",
                    "ios-arm64_x86_64-simulator",
                    "watchos-arm64_x86_64-simulator",
                    "ios-arm64",
                ]
            )
        }
    }

    @Test func withResourcePackage() async throws {
        let runner = Runner(
            mode: .createPackage,
            options: .init(
                baseBuildOptions: .init(
                    platforms: .specific([.iOS]),
                    isSimulatorSupported: true
                ),
                shouldOnlyUseVersionsFromResolvedFile: true,
                cachePolicies: .disabled
            )
        )

        try await runner.run(packageDirectory: resourcePackagePath,
                             frameworkOutputDir: .custom(frameworkOutputDir))

        let xcFramework = frameworkOutputDir.appendingPathComponent("ResourcePackage.xcframework")
        for arch in ["ios-arm64", "ios-arm64_x86_64-simulator"] {
            let frameworkPath = xcFramework
                .appendingPathComponent(arch)
                .appendingPathComponent("ResourcePackage.framework")
            #expect(
                fileManager.fileExists(atPath: frameworkPath.appendingPathComponent("PrivacyInfo.xcprivacy").path),
                "PrivacyInfo.xcprivacy should be located at the expected location"
            )

            let bundlePath = frameworkPath
                .appendingPathComponent("ResourcePackage_ResourcePackage.bundle")
            #expect(
                fileManager.fileExists(atPath: bundlePath.path),
                "A framework for \(arch) should contain resource bundles"
            )
            #expect(
                fileManager.fileExists(atPath: bundlePath.appendingPathComponent("giginet.png").path),
                "Image files should be contained"
            )
            #expect(
                fileManager.fileExists(atPath: bundlePath.appendingPathComponent("AvatarView.nib").path),
                "XIB files should be contained"
            )

            let contents = try #require(try fileManager.contentsOfDirectory(atPath: bundlePath.path))
            #expect(
                Set(contents).isSuperset(of: ["giginet.png", "AvatarView.nib", "Info.plist"]),
                "The resource bundle should contain expected resources"
            )
        }
    }

    @Test func mergeableLibrary() async throws {
        let runner = Runner(
            mode: .createPackage,
            options: .init(
                baseBuildOptions: .init(
                    platforms: .specific([.iOS]),
                    frameworkType: .mergeable
                ),
                shouldOnlyUseVersionsFromResolvedFile: true,
                cachePolicies: .disabled
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
            #expect(
                fileManager.fileExists(atPath: binaryPath.path),
                "A framework for \(arch) should contain binary"
            )

            let executionResult = try await executor.execute("/usr/bin/otool", "-l", binaryPath.path())
            let loadCommands = try #require(try executionResult.unwrapOutput())
            #expect(
                loadCommands.contains("LC_ATOM_INFO"),
                "A Mergeable Library should contain LC_ATOM_INFO segment"
            )
        }
    }

    @Test func withExtraBuildParameters() async throws {
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
            Issue.record("Build should be succeeded. \(error.localizedDescription)")
        }

        for library in ["ScipioTesting"] {
            let xcFramework = frameworkOutputDir.appendingPathComponent("\(library).xcframework")
            let versionFile = frameworkOutputDir.appendingPathComponent(".\(library).version")
            let simulatorFramework = xcFramework.appendingPathComponent("ios-arm64_x86_64-simulator")
            #expect(fileManager.fileExists(atPath: xcFramework.path),
                          "Should create \(library).xcramework")
            #expect(fileManager.fileExists(atPath: versionFile.path),
                          "Should create .\(library).version")
            #expect(!fileManager.fileExists(atPath: simulatorFramework.path),
                           "Should not create Simulator framework")
        }
    }

    @Test func buildXCFrameworkWithNoLibraryEvolution() async throws {
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
            Issue.record("Build should be succeeded. \(error.localizedDescription)")
        }

        for library in ["ScipioTesting"] {
            let xcFramework = frameworkOutputDir.appendingPathComponent("\(library).xcframework")
            let versionFile = frameworkOutputDir.appendingPathComponent(".\(library).version")
            let simulatorFramework = xcFramework.appendingPathComponent("ios-arm64_x86_64-simulator/\(library).framework")
            let deviceFramework = xcFramework.appendingPathComponent("ios-arm64/\(library).framework")

            #expect(
                fileManager.fileExists(atPath: deviceFramework.appendingPathComponent("Headers/\(library)-Swift.h").path),
                "Should exist a bridging header"
            )

            #expect(
                fileManager.fileExists(atPath: deviceFramework.appendingPathComponent("Modules/module.modulemap").path),
                "Should exist a modulemap"
            )

            let expectedSwiftInterface = deviceFramework.appendingPathComponent("Modules/\(library).swiftmodule/arm64-apple-ios.swiftinterface")
            #expect(
                !fileManager.fileExists(atPath: expectedSwiftInterface.path),
                "Should not exist a swiftinterface because emission is disabled"
            )

            #expect(fileManager.fileExists(atPath: xcFramework.path),
                          "Should create \(library).xcramework")
            #expect(fileManager.fileExists(atPath: versionFile.path),
                          "Should create .\(library).version")
            #expect(!fileManager.fileExists(atPath: simulatorFramework.path),
                           "Should not create Simulator framework")
        }
    }

    @Test func generateModuleMapForUmbrellaDirectory() async throws {
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
            Issue.record("Build should be succeeded. \(error.localizedDescription)")
        }

        let xcFramework = frameworkOutputDir.appendingPathComponent("MyTarget.xcframework")

        let deviceFramework = xcFramework.appendingPathComponent("ios-arm64/MyTarget.framework")
        let moduleMapPath = deviceFramework
            .appendingPathComponent("Modules")
            .appendingPathComponent("module.modulemap")
        let headersDirPath = deviceFramework
            .appendingPathComponent("Headers")

        #expect(fileManager.fileExists(atPath: moduleMapPath.path))

        let generatedModuleMapData = try #require(fileManager.contents(atPath: moduleMapPath.path))
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

        #expect(generatedModuleMapContents == expectedModuleMap, "A framework has a valid modulemap")

        let headers = try fileManager.contentsOfDirectory(atPath: headersDirPath.path)
        #expect(headers == [
            "a.h",
            "b.h",
            "add.h",
            "c.h",
            "my_target.h",
        ], "A framework contains all headers")
    }

    deinit {
        try? removeIfExist(at: testPackagePath.appendingPathComponent(".build"))
        try? removeIfExist(at: frameworkOutputDir)
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
        customFrameworkModuleMapContents: nil,
        stripStaticDWARFSymbols: false
    )
}
