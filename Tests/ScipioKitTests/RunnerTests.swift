import Foundation
import Testing
@testable @_spi(Internals) import ScipioKit
import Logging

private let fixturePath = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .appending(components: "Resources", "Fixtures")
private let testPackagePath = fixturePath.appending(component: "E2ETestPackage")
private let binaryPackagePath = fixturePath.appending(component: "BinaryPackage")
private let resourcePackagePath = fixturePath.appending(component: "ResourcePackage")
private let usingBinaryPackagePath = fixturePath.appending(component: "UsingBinaryPackage")
private let clangPackagePath = fixturePath.appending(component: "ClangPackage")
private let clangPackageWithSymbolicLinkHeadersPath = fixturePath.appending(component: "ClangPackageWithSymbolicLinkHeaders")
private let clangPackageWithCustomModuleMapPath = fixturePath.appending(component: "ClangPackageWithCustomModuleMap")
private let clangPackageWithUmbrellaDirectoryPath = fixturePath.appending(component: "ClangPackageWithUmbrellaDirectory")

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
struct RunnerTests {
    private let fileManager: FileManager = .default
    private let plistDecoder: PropertyListDecoder = .init()
    private let frameworkOutputDir: URL

    init() async throws {
        await LoggingTestHelper.shared.bootstrap()
        frameworkOutputDir = TemporaryDirectory.url.appending(component: "XCFrameworks")
        try fileManager.createDirectory(at: frameworkOutputDir, withIntermediateDirectories: true)
    }

    @Test("builds XCFramework with library evolution enabled", .temporaryDirectory)
    func buildXCFramework() async throws {
        let runner = Runner(
            mode: .prepareDependencies,
            options: .init(
                baseBuildOptions: .init(isSimulatorSupported: false, enableLibraryEvolution: true),
                shouldOnlyUseVersionsFromResolvedFile: true
            )
        )
        try await runner.run(packageDirectory: testPackagePath,
                             frameworkOutputDir: .custom(frameworkOutputDir))

        for library in ["ScipioTesting"] {
            let xcFramework = frameworkOutputDir.appending(component: "\(library).xcframework")
            let simulatorFramework = xcFramework.appending(path: "ios-arm64_x86_64-simulator/\(library).framework")
            let deviceFramework = xcFramework.appending(path: "ios-arm64/\(library).framework")

            #expect(
                fileManager.fileExists(atPath: deviceFramework.appending(path: "Headers/\(library)-Swift.h").path),
                "Should exist a bridging header"
            )

            #expect(
                fileManager.fileExists(atPath: deviceFramework.appending(path: "Modules/module.modulemap").path),
                "Should exist a modulemap"
            )

            let expectedSwiftInterface = deviceFramework.appending(path: "Modules/\(library).swiftmodule/arm64-apple-ios.swiftinterface")
            #expect(
                fileManager.fileExists(atPath: expectedSwiftInterface.path),
                "Should exist a swiftinterface"
            )

            let frameworkType = try await detectFrameworkType(of: deviceFramework.appending(component: library))
            #expect(
                frameworkType == .dynamic,
                "Binary should be a dynamic library"
            )

            let infoPlistPath = deviceFramework.appending(component: "Info.plist")
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

    @Test("builds Clang package", .temporaryDirectory)
    func buildClangPackage() async throws {
        let runner = Runner(
            mode: .createPackage,
            options: .init(
                baseBuildOptions: .init(isSimulatorSupported: false),
                shouldOnlyUseVersionsFromResolvedFile: true
            )
        )
        try await runner.run(packageDirectory: clangPackagePath,
                             frameworkOutputDir: .custom(frameworkOutputDir))

        for library in ["some_lib"] {
            let xcFramework = frameworkOutputDir.appending(component: "\(library).xcframework")
            let versionFile = frameworkOutputDir.appending(component: ".\(library).version")
            let framework = xcFramework.appending(path: "ios-arm64/\(library).framework")

            #expect(
                fileManager.fileExists(atPath: framework.appending(path: "Headers/some_lib.h").path),
                "Should exist an umbrella header"
            )

            let moduleMapPath = framework.appending(path: "Modules/module.modulemap").path
            #expect(
                fileManager.fileExists(atPath: moduleMapPath),
                "Should exist a modulemap"
            )
            let moduleMapContents = try #require(fileManager.contents(atPath: moduleMapPath).flatMap { String(decoding: $0, as: UTF8.self) })
            #expect(
                moduleMapContents ==
                """
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

    @Test("builds Clang package with symbolic link headers", .temporaryDirectory)
    func buildClangPackageWithSymbolicLinkHeaders() async throws {
        let runner = Runner(
            mode: .createPackage,
            options: .init(
                baseBuildOptions: .init(isSimulatorSupported: false),
                shouldOnlyUseVersionsFromResolvedFile: true
            )
        )
        try await runner.run(packageDirectory: clangPackageWithSymbolicLinkHeadersPath,
                             frameworkOutputDir: .custom(frameworkOutputDir))

        for library in ["some_lib"] {
            let xcFramework = frameworkOutputDir.appending(component: "\(library).xcframework")
            let versionFile = frameworkOutputDir.appending(component: ".\(library).version")
            let framework = xcFramework.appending(path: "ios-arm64/\(library).framework")

            #expect(
                fileManager.fileExists(atPath: framework.appending(path: "Headers/some_lib.h").path),
                "Should exist an umbrella header"
            )
            #expect(
                fileManager.fileExists(atPath: framework.appending(path: "Headers/a.h").path),
                "Should exist a header from symbolic link"
            )
            #expect(
                fileManager.fileExists(atPath: framework.appending(path: "Headers/b.h").path),
                "Should exist another header from symbolic link"
            )
            #expect(
                !fileManager.fileExists(atPath: framework.appending(path: "Headers/some_lib_dupe.h").path),
                "Should not exist a header from symbolic link which is duplicated to non-symbolic link one"
            )

            let moduleMapPath = framework.appending(path: "Modules/module.modulemap").path
            #expect(
                fileManager.fileExists(atPath: moduleMapPath),
                "Should exist a modulemap"
            )
            let moduleMapContents = try #require(fileManager.contents(atPath: moduleMapPath).flatMap { String(decoding: $0, as: UTF8.self) })
            #expect(
                moduleMapContents ==
                """
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

    @Test("builds Clang package with custom module map", .temporaryDirectory)
    func buildClangPackageWithCustomModuleMap() async throws {
        let runner = Runner(
            mode: .createPackage,
            options: .init(
                baseBuildOptions: .init(isSimulatorSupported: false),
                shouldOnlyUseVersionsFromResolvedFile: true
            )
        )
        try await runner.run(packageDirectory: clangPackageWithCustomModuleMapPath,
                             frameworkOutputDir: .custom(frameworkOutputDir))

        for library in ["ClangPackageWithCustomModuleMap"] {
            let xcFramework = frameworkOutputDir.appending(component: "\(library).xcframework")
            let versionFile = frameworkOutputDir.appending(component: ".\(library).version")
            let framework = xcFramework.appending(path: "ios-arm64/\(library).framework")

            #expect(
                fileManager.fileExists(atPath: framework.appending(path: "Headers/mycalc.h").path),
                "Should exist an umbrella header"
            )

            let moduleMapPath = framework.appending(path: "Modules/module.modulemap").path
            #expect(
                fileManager.fileExists(atPath: moduleMapPath),
                "Should exist a modulemap"
            )
            let moduleMapContents = try #require(fileManager.contents(atPath: moduleMapPath).flatMap { String(decoding: $0, as: UTF8.self) })
            #expect(
                moduleMapContents ==
                """
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

    @Test("validates cache correctly", .temporaryDirectory)
    func cacheIsValid() async throws {
        let descriptionPackage = try await DescriptionPackage(
            packageDirectory: testPackagePath,
            mode: .prepareDependencies,
            resolvedPackagesCachePolicies: [],
            onlyUseVersionsFromResolvedFile: false
        )
        let cacheSystem = CacheSystem(
            outputDirectory: frameworkOutputDir
        )
        let packages = descriptionPackage.graph.allPackages.values
            .filter { $0.manifest.name != descriptionPackage.manifest.name }

        let allTargets = packages
            .flatMap { package in
                package.targets.map { BuildProduct(package: package, target: $0) }
            }
            .map {
                CacheSystem.CacheTarget(buildProduct: $0, buildOptions: .default)
            }

        for product in allTargets {
            try await cacheSystem.generateVersionFile(for: product)
            // generate dummy directory
            try fileManager.createDirectory(
                at: frameworkOutputDir.appending(component: product.buildProduct.frameworkName),
                withIntermediateDirectories: true
            )
        }
        let versionFile2 = frameworkOutputDir.appending(component: ".ScipioTesting.version")
        #expect(fileManager.fileExists(atPath: versionFile2.path))

        let runner = Runner(
            mode: .prepareDependencies,
            options: .init(
                baseBuildOptions: .init(enableLibraryEvolution: true),
                shouldOnlyUseVersionsFromResolvedFile: true,
                frameworkCachePolicies: [.project]
            )
        )
        try await runner.run(packageDirectory: testPackagePath,
                             frameworkOutputDir: .custom(frameworkOutputDir))

        for library in ["ScipioTesting"] {
            let xcFramework = frameworkOutputDir
                .appending(component: "\(library).xcframework")
                .appending(component: "Info.plist")
            let versionFile = frameworkOutputDir.appending(component: ".\(library).version")
            #expect(!fileManager.fileExists(atPath: xcFramework.path),
                           "Should skip to build \(library).xcramework")
            #expect(fileManager.fileExists(atPath: versionFile.path),
                          "Should create .\(library).version")
        }
    }

    @Test("uses local disk cache storage", .temporaryDirectory)
    func localDiskCacheStorage() async throws {
        let tempDir = TemporaryDirectory.url
        let storage = LocalDiskCacheStorage(baseURL: tempDir)
        let storageDir = tempDir.appending(component: "Scipio")

        let runner = Runner(
            mode: .prepareDependencies,
            options: .init(
                shouldOnlyUseVersionsFromResolvedFile: true,
                frameworkCachePolicies: [
                    .init(storage: storage, actors: [.consumer, .producer]),
                ]
            )
        )
        try await runner.run(packageDirectory: testPackagePath,
                             frameworkOutputDir: .custom(frameworkOutputDir))

        #expect(
            fileManager.fileExists(atPath: storageDir.appending(component: "ScipioTesting").path),
            "The framework should be cached to the cache storage"
        )

        try self.fileManager.removeItem(atPath: frameworkOutputDir.path)

        // Fetch from local storage
        try await runner.run(packageDirectory: testPackagePath,
                             frameworkOutputDir: .custom(frameworkOutputDir))

        let outputFrameworkPath = frameworkOutputDir.appending(component: "ScipioTesting.xcframework")
        let outputVersionFile = frameworkOutputDir.appending(component: ".ScipioTesting.version")

        #expect(
            fileManager.fileExists(atPath: outputFrameworkPath.path),
            "The framework should be restored from the cache storage"
        )
        #expect(
            fileManager.fileExists(atPath: outputVersionFile.path),
            "The version file should exist when restored"
        )
    }

    @Test("uses multiple cache policies", .temporaryDirectory)
    func multipleCachePolicies() async throws {
        let tempDir = TemporaryDirectory.url
        let storage1CacheDir = tempDir.appending(path: "storage1", directoryHint: .isDirectory)
        let storage1 = LocalDiskCacheStorage(baseURL: storage1CacheDir)
        let storage1Dir = storage1CacheDir.appending(component: "Scipio")

        let storage2CacheDir = tempDir.appending(path: "storage2", directoryHint: .isDirectory)
        let storage2 = LocalDiskCacheStorage(baseURL: storage2CacheDir)
        let storage2Dir = storage2CacheDir.appending(component: "Scipio")

        let runner = Runner(
            mode: .prepareDependencies,
            options: .init(
                shouldOnlyUseVersionsFromResolvedFile: true,
                frameworkCachePolicies: [
                    .init(storage: storage1, actors: [.consumer, .producer]),
                    .init(storage: storage2, actors: [.consumer, .producer]),
                ]
            )
        )
        try await runner.run(packageDirectory: testPackagePath,
                             frameworkOutputDir: .custom(frameworkOutputDir))

        // The cache are stored into 2 storages
        #expect(
            fileManager.fileExists(atPath: storage1Dir.appending(component: "ScipioTesting").path),
            "The framework should be cached to the 1st cache storage"
        )
        #expect(
            fileManager.fileExists(atPath: storage2Dir.appending(component: "ScipioTesting").path),
            "The framework should be cached to the 2nd cache storage as well"
        )

        let outputFrameworkPath = frameworkOutputDir.appending(component: "ScipioTesting.xcframework")
        try self.fileManager.removeItem(atPath: outputFrameworkPath.path)

        // Remove the storage1's cache so storage2's cache should be used instead
        try fileManager.removeItem(at: storage1Dir.appending(component: "ScipioTesting"))
        try await runner.run(packageDirectory: testPackagePath,
                             frameworkOutputDir: .custom(frameworkOutputDir))

        #expect(
            fileManager.fileExists(atPath: outputFrameworkPath.path),
            "The framework should be restored from the 2nd cache storage"
        )
    }

    @Test("extracts binary frameworks", .temporaryDirectory)
    func extractBinary() async throws {
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
                frameworkCachePolicies: [.project],
                overwrite: false,
                verbose: false)
        )

        try await runner.run(packageDirectory: binaryPackagePath, frameworkOutputDir: .custom(frameworkOutputDir))

        let binaryPath = frameworkOutputDir.appending(component: "SomeBinary.xcframework")
        #expect(
            fileManager.fileExists(atPath: binaryPath.path),
            "Binary frameworks should be copied."
        )
    }

    @Test("prepares binary frameworks with version file", .temporaryDirectory)
    func prepareBinary() async throws {
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
                frameworkCachePolicies: [.project],
                overwrite: false,
                verbose: false)
        )

        try await runner.run(packageDirectory: usingBinaryPackagePath, frameworkOutputDir: .custom(frameworkOutputDir))

        let binaryPath = frameworkOutputDir.appending(component: "SomeBinary.xcframework")
        #expect(
            fileManager.fileExists(atPath: binaryPath.path),
            "Binary frameworks should be copied."
        )

        let versionFilePath = frameworkOutputDir.appending(component: ".SomeBinary.version")
        #expect(
            fileManager.fileExists(atPath: versionFilePath.path),
            "Version files should be created"
        )
    }

    @Test("validates binary cache correctly", .temporaryDirectory)
    func binaryHasValidCache() async throws {
        // Generate VersionFile
        let descriptionPackage = try await DescriptionPackage(
            packageDirectory: usingBinaryPackagePath,
            mode: .prepareDependencies,
            resolvedPackagesCachePolicies: [],
            onlyUseVersionsFromResolvedFile: false
        )
        let cacheSystem = CacheSystem(
            outputDirectory: frameworkOutputDir
        )
        let packages = descriptionPackage.graph.allPackages.values
            .filter { $0.manifest.name != descriptionPackage.manifest.name }

        let allTargets = packages
            .flatMap { package in
                package.targets.map { BuildProduct(package: package, target: $0) }
            }
            .map {
                CacheSystem.CacheTarget(buildProduct: $0, buildOptions: .default)
            }

        for product in allTargets {
            try await cacheSystem.generateVersionFile(for: product)
            // generate dummy directory
            try fileManager.createDirectory(
                at: frameworkOutputDir.appending(component: product.buildProduct.frameworkName),
                withIntermediateDirectories: true
            )
        }
        let versionFile2 = frameworkOutputDir.appending(component: ".SomeBinary.version")
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
                frameworkCachePolicies: [.project],
                overwrite: false,
                verbose: false)
        )

        try await runner.run(packageDirectory: usingBinaryPackagePath, frameworkOutputDir: .custom(frameworkOutputDir))

        let binaryPath = frameworkOutputDir.appending(component: "SomeBinary.xcframework")
        #expect(
            fileManager.fileExists(atPath: binaryPath.path),
            "Binary frameworks should be copied."
        )

        // We generated an empty XCFramework directory to simulate cache is valid before.
        // So if runner doesn't create valid XCFrameworks, framework's contents are not exists
        let infoPlistPath = binaryPath.appending(component: "Info.plist")
        #expect(
            !fileManager.fileExists(atPath: infoPlistPath.path),
            "XCFramework should not be updated"
        )
    }

    @Test("builds with platform matrix", .temporaryDirectory)
    func withPlatformMatrix() async throws {
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
                frameworkCachePolicies: [.project],
                overwrite: false,
                verbose: false)
        )

        try await runner.run(packageDirectory: testPackagePath,
                             frameworkOutputDir: .custom(frameworkOutputDir))

        for library in ["ScipioTesting"] {
            let xcFramework = frameworkOutputDir.appending(component: "\(library).xcframework")
            let versionFile = frameworkOutputDir.appending(component: ".\(library).version")
            let contentsOfXCFramework = try fileManager.contentsOfDirectory(atPath: xcFramework.path)
            #expect(fileManager.fileExists(atPath: xcFramework.path),
                          "Should create \(library).xcramework")
            #expect(fileManager.fileExists(atPath: versionFile.path),
                          "Should create .\(library).version")
            #expect(
                Set(contentsOfXCFramework) ==
                [
                    "Info.plist",
                    "watchos-arm64_arm64_32_armv7k",
                    "ios-arm64_x86_64-simulator",
                    "watchos-arm64_x86_64-simulator",
                    "ios-arm64",
                ]
            )
        }
    }

    @Test("builds resource package correctly", .temporaryDirectory)
    func withResourcePackage() async throws {
        let runner = Runner(
            mode: .createPackage,
            options: .init(
                baseBuildOptions: .init(
                    platforms: .specific([.iOS]),
                    isSimulatorSupported: true
                ),
                shouldOnlyUseVersionsFromResolvedFile: true,
                frameworkCachePolicies: .disabled
            )
        )

        try await runner.run(packageDirectory: resourcePackagePath,
                             frameworkOutputDir: .custom(frameworkOutputDir))

        let xcFramework = frameworkOutputDir.appending(component: "ResourcePackage.xcframework")
        for arch in ["ios-arm64", "ios-arm64_x86_64-simulator"] {
            let frameworkPath = xcFramework
                .appending(component: arch)
                .appending(component: "ResourcePackage.framework")
            #expect(
                fileManager.fileExists(atPath: frameworkPath.appending(component: "PrivacyInfo.xcprivacy").path),
                "PrivacyInfo.xcprivacy should be located at the expected location"
            )

            let bundlePath = frameworkPath
                .appending(component: "ResourcePackage_ResourcePackage.bundle")
            #expect(
                fileManager.fileExists(atPath: bundlePath.path),
                "A framework for \(arch) should contain resource bundles"
            )
            #expect(
                fileManager.fileExists(atPath: bundlePath.appending(component: "giginet.png").path),
                "Image files should be contained"
            )
            #expect(
                fileManager.fileExists(atPath: bundlePath.appending(component: "AvatarView.nib").path),
                "XIB files should be contained"
            )
            #expect(
                fileManager.fileExists(atPath: bundlePath.appending(component: "Assets.car").path),
                "Assets.car files should be contained"
            )
            #expect(
                fileManager.fileExists(atPath: bundlePath.appending(component: "Model.momd").path),
                "Model.momd files should be contained"
            )

            let contents = try fileManager.contentsOfDirectory(atPath: bundlePath.path)
            #expect(
                Set(contents).isSuperset(of: ["giginet.png", "AvatarView.nib", "Info.plist", "Assets.car", "Model.momd"]),
                "The resource bundle should contain expected resources"
            )
        }
    }

    @Test("builds mergeable library", .temporaryDirectory)
    func mergeableLibrary() async throws {
        let runner = Runner(
            mode: .createPackage,
            options: .init(
                baseBuildOptions: .init(
                    platforms: .specific([.iOS]),
                    frameworkType: .mergeable
                ),
                shouldOnlyUseVersionsFromResolvedFile: true,
                frameworkCachePolicies: .disabled
            )
        )

        try await runner.run(packageDirectory: testPackagePath,
                             frameworkOutputDir: .custom(frameworkOutputDir))

        let xcFramework = frameworkOutputDir.appending(component: "TestingPackage.xcframework")

        let executor = ProcessExecutor()

        for arch in ["ios-arm64"] {
            let binaryPath = xcFramework
                .appending(component: arch)
                .appending(component: "TestingPackage.framework")
                .appending(component: "TestingPackage")
            #expect(
                fileManager.fileExists(atPath: binaryPath.path),
                "A framework for \(arch) should contain binary"
            )

            let executionResult = try await executor.execute("/usr/bin/otool", "-l", binaryPath.path())
            let loadCommands = try executionResult.unwrapOutput()
            #expect(
                loadCommands.contains("LC_ATOM_INFO"),
                "A Mergeable Library should contain LC_ATOM_INFO segment"
            )
        }
    }

    @Test("builds with extra build parameters", .temporaryDirectory)
    func withExtraBuildParameters() async throws {
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

        try await runner.run(packageDirectory: testPackagePath,
                             frameworkOutputDir: .custom(frameworkOutputDir))

        for library in ["ScipioTesting"] {
            let xcFramework = frameworkOutputDir.appending(component: "\(library).xcframework")
            let versionFile = frameworkOutputDir.appending(component: ".\(library).version")
            let simulatorFramework = xcFramework.appending(component: "ios-arm64_x86_64-simulator")
            #expect(fileManager.fileExists(atPath: xcFramework.path),
                          "Should create \(library).xcramework")
            #expect(fileManager.fileExists(atPath: versionFile.path),
                          "Should create .\(library).version")
            #expect(!fileManager.fileExists(atPath: simulatorFramework.path),
                           "Should not create Simulator framework")
        }
    }

    @Test("builds XCFramework without library evolution", .temporaryDirectory)
    func buildXCFrameworkWithNoLibraryEvolution() async throws {
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
        try await runner.run(packageDirectory: testPackagePath,
                             frameworkOutputDir: .custom(frameworkOutputDir))

        for library in ["ScipioTesting"] {
            let xcFramework = frameworkOutputDir.appending(component: "\(library).xcframework")
            let versionFile = frameworkOutputDir.appending(component: ".\(library).version")
            let simulatorFramework = xcFramework.appending(path: "ios-arm64_x86_64-simulator/\(library).framework")
            let deviceFramework = xcFramework.appending(path: "ios-arm64/\(library).framework")

            #expect(
                fileManager.fileExists(atPath: deviceFramework.appending(path: "Headers/\(library)-Swift.h").path),
                "Should exist a bridging header"
            )

            #expect(
                fileManager.fileExists(atPath: deviceFramework.appending(path: "Modules/module.modulemap").path),
                "Should exist a modulemap"
            )

            let expectedSwiftInterface = deviceFramework.appending(path: "Modules/\(library).swiftmodule/arm64-apple-ios.swiftinterface")
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

    @Test("generates module map for umbrella directory", .temporaryDirectory)
    func generateModuleMapForUmbrellaDirectory() async throws {
        let runner = Runner(
            mode: .createPackage,
            options: .init(
                baseBuildOptions: .init(platforms: .specific([.iOS])),
                shouldOnlyUseVersionsFromResolvedFile: true
            )
        )
        try await runner.run(packageDirectory: clangPackageWithUmbrellaDirectoryPath,
                             frameworkOutputDir: .custom(frameworkOutputDir))

        let xcFramework = frameworkOutputDir.appending(component: "MyTarget.xcframework")

        let deviceFramework = xcFramework.appending(path: "ios-arm64/MyTarget.framework")
        let moduleMapPath = deviceFramework
            .appending(component: "Modules")
            .appending(component: "module.modulemap")
        let headersDirPath = deviceFramework
            .appending(component: "Headers")

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
