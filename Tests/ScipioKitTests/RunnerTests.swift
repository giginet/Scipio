import Foundation
import XCTest
@testable @_spi(Internals) import ScipioKit
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
private let clangPackageWithInterdependentHeadersPath = fixturePath.appendingPathComponent("ClangPackageWithInterdependentHeaders")
private let packageWithSystemLibraryTargetPath = fixturePath.appendingPathComponent("PackageWithSystemLibraryTarget")

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
        Task {
            await LoggingTestHelper.shared.bootstrap()
        }

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

    func testBuildClangPackageRewritesInterdependentHeaderIncludes() async throws {
        // Use keepPublicHeadersStructure so the nested `core/core.h` layout survives into the framework.
        let runner = Runner(
            mode: .createPackage,
            options: .init(
                baseBuildOptions: .init(isSimulatorSupported: false, keepPublicHeadersStructure: true),
                shouldOnlyUseVersionsFromResolvedFile: true
            )
        )
        do {
            try await runner.run(packageDirectory: clangPackageWithInterdependentHeadersPath,
                                 frameworkOutputDir: .custom(frameworkOutputDir))
        } catch {
            XCTFail("Build should be succeeded. \(error.localizedDescription)")
        }

        let featureSlice = frameworkOutputDir
            .appendingPathComponent("Feature.xcframework")
            .appendingPathComponent("ios-arm64")
        let coreLibSlice = frameworkOutputDir
            .appendingPathComponent("CoreLib.xcframework")
            .appendingPathComponent("ios-arm64")

        // `Feature`'s public header does `#include <core/core.h>`. In the prebuilt framework it must
        // be rewritten to the framework-relative `<CoreLib/core/core.h>` so consumers resolve it via
        // `-F` instead of a `-I` that only SwiftPM would inject.
        let featureHeaderPath = featureSlice
            .appendingPathComponent("Feature.framework")
            .appendingPathComponent("Headers/feature.h")
            .path
        let headerContents = try XCTUnwrap(
            fileManager.contents(atPath: featureHeaderPath).flatMap { String(decoding: $0, as: UTF8.self) }
        )
        XCTAssertTrue(
            headerContents.contains("#include <CoreLib/core/core.h>"),
            "Angle-bracket include should be rewritten to framework form, got:\n\(headerContents)"
        )
        XCTAssertFalse(
            headerContents.contains("#include <core/core.h>"),
            "Original non-framework include should be gone"
        )

        // The rewritten path must actually exist in the dependency framework, otherwise the include
        // is still unresolvable under `-F`. Its same-module include of a sibling public header must
        // be rewritten as well.
        let coreHeaderPath = coreLibSlice
            .appendingPathComponent("CoreLib.framework")
            .appendingPathComponent("Headers/core/core.h")
            .path
        let coreHeaderContents = try XCTUnwrap(
            fileManager.contents(atPath: coreHeaderPath).flatMap { String(decoding: $0, as: UTF8.self) },
            "CoreLib framework should expose the header at the rewritten path"
        )
        XCTAssertTrue(
            coreHeaderContents.contains("#include <CoreLib/core/core_types.h>"),
            "Same-module include should be rewritten to framework form, got:\n\(coreHeaderContents)"
        )

        // Inline-implementation files are textual headers: they must ship with the framework
        // and includes pointing at them must be rewritten like any other header.
        XCTAssertTrue(
            fileManager.fileExists(
                atPath: coreLibSlice
                    .appendingPathComponent("CoreLib.framework")
                    .appendingPathComponent("Headers/core/core_inline.inl")
                    .path
            ),
            "Inline-implementation file should be shipped with the framework"
        )
        XCTAssertTrue(
            coreHeaderContents.contains("#include <CoreLib/core/core_inline.inl>"),
            "Include of the inline-implementation file should be rewritten, got:\n\(coreHeaderContents)"
        )

        // A quoted include that only the injected search paths could resolve is rewritten like
        // an angle include; quoted lookup has no includer-relative candidate for it here.
        XCTAssertTrue(
            coreHeaderContents.contains("#include <CoreLib/core/core_quoted.h>"),
            "Search-path style quoted include should be rewritten, got:\n\(coreHeaderContents)"
        )

        // Prove a consumer can compile against the produced frameworks using only framework search
        // (`-F`), with none of the `-I` paths SwiftPM would otherwise inject.
        let sdkPath = try runProcess("/usr/bin/xcrun", ["--sdk", "iphoneos", "--show-sdk-path"])
        XCTAssertEqual(sdkPath.status, 0, "Should resolve the iphoneos SDK path")

        let consumerSource = tempDir.appendingPathComponent("header_rewrite_consumer.c")
        try "#include <Feature/feature.h>\n".write(to: consumerSource, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: consumerSource) }

        let compile = try runProcess("/usr/bin/xcrun", [
            "--sdk", "iphoneos", "clang",
            "-target", "arm64-apple-ios12.0",
            "-isysroot", sdkPath.output.trimmingCharacters(in: .whitespacesAndNewlines),
            "-F", featureSlice.path,
            "-F", coreLibSlice.path,
            "-fsyntax-only",
            "-x", "c", consumerSource.path,
        ])
        XCTAssertEqual(
            compile.status, 0,
            "Consumer should compile using only -F (framework search). Output:\n\(compile.output)"
        )
    }

    func testBuildPackageWithSystemLibraryTarget() async throws {
        let runner = Runner(
            mode: .createPackage,
            options: .init(
                // Dynamic linking (explicitly, not by default) so a missing system-module skip in
                // PIFGenerator's linker-flag injection fails this test with `framework not found`.
                baseBuildOptions: .init(
                    isSimulatorSupported: true,
                    frameworkType: .dynamic,
                    keepPublicHeadersStructure: true
                ),
                shouldOnlyUseVersionsFromResolvedFile: true
            )
        )
        do {
            try await runner.run(packageDirectory: packageWithSystemLibraryTargetPath,
                                 frameworkOutputDir: .custom(frameworkOutputDir))
        } catch {
            XCTFail("Build should be succeeded. \(error.localizedDescription)")
        }

        for xcFrameworkName in ["MainLib.xcframework", "CoreLib.xcframework", "SysShim.xcframework"] {
            XCTAssertTrue(
                fileManager.fileExists(atPath: frameworkOutputDir.appendingPathComponent(xcFrameworkName).path),
                "\(xcFrameworkName) should be produced"
            )
        }

        let sysShimFramework = frameworkOutputDir
            .appendingPathComponent("SysShim.xcframework")
            .appendingPathComponent("ios-arm64")
            .appendingPathComponent("SysShim.framework")

        XCTAssertTrue(
            fileManager.fileExists(atPath: sysShimFramework.appendingPathComponent("SysShim").path),
            "The framework should contain the stub binary"
        )
        XCTAssertTrue(
            fileManager.fileExists(atPath: sysShimFramework.appendingPathComponent("Info.plist").path),
            "The framework should contain a generated Info.plist"
        )

        // The simulator stub merges one object per architecture into a single archive.
        let simulatorStubPath = frameworkOutputDir
            .appendingPathComponent("SysShim.xcframework")
            .appendingPathComponent("ios-arm64_x86_64-simulator")
            .appendingPathComponent("SysShim.framework/SysShim")
            .path
        let lipoInfo = try runProcess("/usr/bin/xcrun", ["lipo", "-info", simulatorStubPath])
        XCTAssertEqual(lipoInfo.status, 0, "The simulator slice should contain a stub binary")
        XCTAssertTrue(
            lipoInfo.output.contains("x86_64") && lipoInfo.output.contains("arm64"),
            "The simulator stub should cover both architectures, got:\n\(lipoInfo.output)"
        )

        let moduleMapPath = sysShimFramework.appendingPathComponent("Modules/module.modulemap").path
        let moduleMapContents = try XCTUnwrap(
            fileManager.contents(atPath: moduleMapPath).flatMap { String(decoding: $0, as: UTF8.self) }
        )
        XCTAssertTrue(
            moduleMapContents.contains("framework module SysShim"),
            "The module map should declare a framework module, got:\n\(moduleMapContents)"
        )

        let shimHeaderPath = sysShimFramework.appendingPathComponent("Headers/shim.h").path
        let shimHeaderContents = try XCTUnwrap(
            fileManager.contents(atPath: shimHeaderPath).flatMap { String(decoding: $0, as: UTF8.self) }
        )
        XCTAssertTrue(
            shimHeaderContents.contains("#include <CoreLib/core/core.h>"),
            "Angle-bracket include should be rewritten to framework form, got:\n\(shimHeaderContents)"
        )
        XCTAssertFalse(
            shimHeaderContents.contains("#include <core/core.h>"),
            "Original non-framework include should be gone"
        )

        // Importing the Swift module that itself imports the system-library module must resolve
        // with only -F: the consumer-side `missing required module` failure this PR removes.
        let sdkPath = try runProcess("/usr/bin/xcrun", ["--sdk", "iphoneos", "--show-sdk-path"])
        XCTAssertEqual(sdkPath.status, 0, "Should resolve the iphoneos SDK path")

        let consumerSource = tempDir.appendingPathComponent("system_library_consumer.swift")
        try """
        import MainLib
        import SysShim

        func consumerValue() -> sys_shim_value_t {
            mainLibValue()
        }

        """.write(to: consumerSource, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: consumerSource) }

        let frameworkSearchPaths = ["MainLib", "CoreLib", "SysShim"].flatMap { name in
            ["-F", frameworkOutputDir.appendingPathComponent("\(name).xcframework/ios-arm64").path]
        }
        let compile = try runProcess("/usr/bin/xcrun", [
            "--sdk", "iphoneos", "swiftc",
            "-typecheck",
            "-target", "arm64-apple-ios12.0",
            "-sdk", sdkPath.output.trimmingCharacters(in: .whitespacesAndNewlines),
        ] + frameworkSearchPaths + [
            consumerSource.path,
        ])
        XCTAssertEqual(
            compile.status, 0,
            "Consumer should compile using only -F (framework search). Output:\n\(compile.output)"
        )
    }

    private func runProcess(_ launchPath: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Drain the pipe before waiting: waiting first deadlocks once output exceeds the pipe buffer.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
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
                frameworkCachePolicies: [.project]
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
                frameworkCachePolicies: [
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

        try self.fileManager.removeItem(atPath: frameworkOutputDir.path)

        // Fetch from local storage
        do {
            try await runner.run(packageDirectory: testPackagePath,
                                 frameworkOutputDir: .custom(frameworkOutputDir))
        } catch {
            XCTFail("Build should be succeeded.")
        }

        let outputFrameworkPath = frameworkOutputDir.appendingPathComponent("ScipioTesting.xcframework")
        let outputVersionFile = frameworkOutputDir.appendingPathComponent(".ScipioTesting.version")

        XCTAssertTrue(
            fileManager.fileExists(atPath: outputFrameworkPath.path),
            "The framework should be restored from the cache storage"
        )
        XCTAssertTrue(
            fileManager.fileExists(atPath: outputVersionFile.path),
            "The version file should exist when restored"
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
                frameworkCachePolicies: [
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
                frameworkCachePolicies: [.project],
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
                frameworkCachePolicies: [.project],
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
                frameworkCachePolicies: [.project],
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
                    "watchos-arm64_x86_64-simulator",
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
                frameworkCachePolicies: .disabled
            )
        )

        try await runner.run(packageDirectory: resourcePackagePath,
                             frameworkOutputDir: .custom(frameworkOutputDir))

        let xcFramework = frameworkOutputDir.appendingPathComponent("ResourcePackage.xcframework")
        for arch in ["ios-arm64", "ios-arm64_x86_64-simulator"] {
            let frameworkPath = xcFramework
                .appendingPathComponent(arch)
                .appendingPathComponent("ResourcePackage.framework")
            XCTAssertTrue(
                fileManager.fileExists(atPath: frameworkPath.appendingPathComponent("PrivacyInfo.xcprivacy").path),
                "PrivacyInfo.xcprivacy should be located at the expected location"
            )

            let bundlePath = frameworkPath
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
            XCTAssertTrue(
                fileManager.fileExists(atPath: bundlePath.appending(component: "Assets.car").path),
                "Assets.car files should be contained"
            )
            XCTAssertTrue(
                fileManager.fileExists(atPath: bundlePath.appending(component: "Model.momd").path),
                "Model.momd files should be contained"
            )

            let contents = try XCTUnwrap(try fileManager.contentsOfDirectory(atPath: bundlePath.path))
            XCTAssertTrue(
                Set(contents).isSuperset(of: ["giginet.png", "AvatarView.nib", "Info.plist", "Assets.car", "Model.momd"]),
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
                frameworkCachePolicies: .disabled
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
        customFrameworkModuleMapContents: nil,
        stripStaticDWARFSymbols: false
    )
}
