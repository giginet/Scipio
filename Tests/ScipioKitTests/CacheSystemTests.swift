import Foundation
@testable import ScipioKit
import XCTest
import TSCBasic

private let fixturePath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources")
    .appendingPathComponent("Fixtures")

final class CacheSystemTests: XCTestCase {

    private let customModuleMap = """
    framework module MyTarget {
        umbrella header "umbrella.h"
        export *
    }
    """

    func testEncodeCacheKey() throws {
        let cacheKey = SwiftPMCacheKey(
            localPackageCanonicalLocation: "/path/to/MyPackage",
            pin: .init(revision: "111111111"),
            targetName: "MyTarget",
            buildOptions: .init(
                buildConfiguration: .release,
                isDebugSymbolsEmbedded: false,
                frameworkType: .dynamic,
                sdks: [.iOS],
                extraFlags: .init(swiftFlags: ["-D", "SOME_FLAG"]),
                extraBuildParameters: ["SWIFT_OPTIMIZATION_LEVEL": "-Osize"],
                enableLibraryEvolution: true,
                keepPublicHeadersStructure: false,
                customFrameworkModuleMapContents: Data(customModuleMap.utf8),
                stripStaticDWARFSymbols: false
            ),
            clangVersion: "clang-1400.0.29.102",
            xcodeVersion: .init(xcodeVersion: "15.4", xcodeBuildVersion: "15F31d")
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(cacheKey)
        let rawString = try XCTUnwrap(String(decoding: data, as: UTF8.self))

        // swiftlint:disable line_length
        let expected = """
        {
          "buildOptions" : {
            "buildConfiguration" : "release",
            "customFrameworkModuleMapContents" : "ZnJhbWV3b3JrIG1vZHVsZSBNeVRhcmdldCB7CiAgICB1bWJyZWxsYSBoZWFkZXIgInVtYnJlbGxhLmgiCiAgICBleHBvcnQgKgp9",
            "enableLibraryEvolution" : true,
            "extraBuildParameters" : {
              "SWIFT_OPTIMIZATION_LEVEL" : "-Osize"
            },
            "extraFlags" : {
              "swiftFlags" : [
                "-D",
                "SOME_FLAG"
              ]
            },
            "frameworkType" : "dynamic",
            "isDebugSymbolsEmbedded" : false,
            "keepPublicHeadersStructure" : false,
            "sdks" : [
              "iOS"
            ],
            "stripStaticDWARFSymbols" : false
          },
          "clangVersion" : "clang-1400.0.29.102",
          "localPackageCanonicalLocation" : "\\/path\\/to\\/MyPackage",
          "pin" : {
            "revision" : "111111111"
          },
          "targetName" : "MyTarget",
          "xcodeVersion" : {
            "xcodeBuildVersion" : "15F31d",
            "xcodeVersion" : "15.4"
          }
        }
        """
        // swiftlint:enable line_length
        XCTAssertEqual(rawString, expected)
    }

    func testCacheKeyForRemoteAndLocalPackageDifference() async throws {
        let fileSystem = LocalFileSystem.default

        let tempDir = fileSystem.tempDirectory.appending(component: #function)
        try fileSystem.removeFileTree(tempDir)
        try fileSystem.createDirectory(tempDir)


        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tempCacheKeyTestsDir = tempDir.appending(component: "CacheKeyTests")
        try await fileSystem.copy(
            from: fixturePath.appending(component: "CacheKeyTests"),
            to: tempCacheKeyTestsDir
        )

        // For local package consumption
        let executor = ProcessExecutor()
        _ = try await executor.execute([
            "git",
            "clone",
            "https://github.com/giginet/scipio-testing",
            tempDir.appending(component: "scipio-testing").path(percentEncoded: false),
            "-b",
            "3.0.0",
            "--depth",
            "1",
        ])

        func scipioTestingCacheKey(fixture: String) async throws -> SwiftPMCacheKey {
            let descriptionPackage = try await DescriptionPackage(
                packageDirectory: tempCacheKeyTestsDir.appending(component: fixture).absolutePath,
                mode: .createPackage,
                onlyUseVersionsFromResolvedFile: false
            )
            let package = descriptionPackage
                .graph
                .allPackages
                .values
                .first { $0.manifest.name == "scipio-testing" }!
            let target = package.targets.first { $0.name == "ScipioTesting" }!
            let cacheTarget = CacheSystem.CacheTarget(
                buildProduct: BuildProduct(
                    package: package,
                    target: target
                ),
                buildOptions: BuildOptions(
                    buildConfiguration: .release,
                    isDebugSymbolsEmbedded: false,
                    frameworkType: .dynamic,
                    sdks: [.iOS, .iOSSimulator],
                    extraFlags: nil,
                    extraBuildParameters: nil,
                    enableLibraryEvolution: false,
                    keepPublicHeadersStructure: false,
                    customFrameworkModuleMapContents: nil,
                    stripStaticDWARFSymbols: false
                )
            )

            let cacheSystem = CacheSystem(
                outputDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("XCFrameworks")
            )
            return try await cacheSystem.calculateCacheKey(of: cacheTarget)
        }

        let scipioTestingRemote = try await scipioTestingCacheKey(fixture: "AsRemotePackage")
        let scipioTestingLocal = try await scipioTestingCacheKey(fixture: "AsLocalPackage")

        XCTAssertNil(scipioTestingRemote.localPackageCanonicalLocation)
        XCTAssertEqual(
            scipioTestingLocal.localPackageCanonicalLocation,
            ScipioKit.CanonicalPackageLocation(
                tempDir.appending(component: "scipio-testing")
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .path(percentEncoded: false)
            ).description
        )
        XCTAssertEqual(scipioTestingRemote.targetName, scipioTestingLocal.targetName)
        XCTAssertEqual(scipioTestingRemote.pin, scipioTestingLocal.pin)
    }

    func testCacheKeyCalculationForRootPackageTarget() async throws {
        let fileSystem = LocalFileSystem.default
        let testingPackagePath = fixturePath.appendingPathComponent("TestingPackage")
        let tempTestingPackagePath = fileSystem.tempDirectory.appending(component: "temp_TestingPackage")

        try await fileSystem.removeFileTree(tempTestingPackagePath)
        try await fileSystem.copy(from: testingPackagePath, to: tempTestingPackagePath)

        defer { try? FileManager.default.removeItem(at: tempTestingPackagePath) }

        let descriptionPackage = try await DescriptionPackage(
            packageDirectory: tempTestingPackagePath.absolutePath,
            mode: .createPackage,
            onlyUseVersionsFromResolvedFile: false
        )
        let cacheSystem = CacheSystem(
            outputDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("XCFrameworks")
        )
        let testingPackage = descriptionPackage
            .graph
            .allPackages
            .values
            .first { $0.manifest.name == descriptionPackage.manifest.name }!

        let myTarget = testingPackage.targets.first { $0.name == "MyTarget" }!
        let cacheTarget = CacheSystem.CacheTarget(
            buildProduct: BuildProduct(
                package: testingPackage,
                target: myTarget
            ),
            buildOptions: BuildOptions(
                buildConfiguration: .release,
                isDebugSymbolsEmbedded: false,
                frameworkType: .dynamic,
                sdks: [.iOS, .iOSSimulator],
                extraFlags: nil,
                extraBuildParameters: nil,
                enableLibraryEvolution: false,
                keepPublicHeadersStructure: false,
                customFrameworkModuleMapContents: nil,
                stripStaticDWARFSymbols: false
            )
        )

        // Ensure that the cache key cannot be calculated if the package is not in the Git repository.
        do {
            _ = try await cacheSystem.calculateCacheKey(of: cacheTarget)
            XCTFail("A cache key should not be possible to calculate if the package is not in a repository.")
        } catch let error as CacheSystem.Error {
            XCTAssertEqual(error.errorDescription, "Repository version is not detected for \(descriptionPackage.name).")
        } catch {
            XCTFail("Wrong error type.")
        }

        // Ensure that the cache key is properly calculated when the package is in a repository with the correct tag."
        let processExecutor: Executor = ProcessExecutor()
        try await processExecutor.execute(["git", "init", tempTestingPackagePath.path(percentEncoded: false)])
        try await processExecutor.execute(["git", "-C", tempTestingPackagePath.path(percentEncoded: false), "add", tempTestingPackagePath.path(percentEncoded: false)])
        try await processExecutor.execute(["git", "-C", tempTestingPackagePath.path(percentEncoded: false), "commit", "-m", "Initial commit"])
        try await processExecutor.execute(["git", "-C", tempTestingPackagePath.path(percentEncoded: false), "tag", "v1.1"])

        let cacheKey = try await cacheSystem.calculateCacheKey(of: cacheTarget)

        XCTAssertEqual(cacheKey.targetName, myTarget.name)
        XCTAssertEqual(cacheKey.pin.version, "1.1.0")
    }
}
