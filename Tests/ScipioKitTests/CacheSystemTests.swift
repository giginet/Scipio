import Foundation
@testable import ScipioKit
import XCTest

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

    private let testingPackagePath = fixturePath.appendingPathComponent("TestingPackage")

    func testEncodeCacheKey() throws {
        let cacheKey = SwiftPMCacheKey(targetName: "MyTarget",
                                       pin: .revision("111111111"),
                                       buildOptions: .init(buildConfiguration: .release,
                                                           isDebugSymbolsEmbedded: false,
                                                           frameworkType: .dynamic,
                                                           sdks: [.iOS],
                                                           extraFlags: .init(swiftFlags: ["-D", "SOME_FLAG"]),
                                                           extraBuildParameters: ["SWIFT_OPTIMIZATION_LEVEL": "-Osize"],
                                                           enableLibraryEvolution: true,
                                                           customFrameworkModuleMapContents: Data(customModuleMap.utf8)
                                                          ),
                                       clangVersion: "clang-1400.0.29.102",
                                       xcodeVersion: .init(xcodeVersion: "15.4", xcodeBuildVersion: "15F31d")
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(cacheKey)
        let rawString = try XCTUnwrap(String(decoding: data, as: UTF8.self))
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
            "sdks" : [
              "iOS"
            ]
          },
          "clangVersion" : "clang-1400.0.29.102",
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
        XCTAssertEqual(rawString, expected)
    }

    func testCacheKeyCalculationForRootPackageTarget() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let frameworkOutputDir = tempDir.appendingPathComponent("XCFrameworks")
        let descriptionPackage = try DescriptionPackage(
            packageDirectory: testingPackagePath.absolutePath,
            mode: .createPackage,
            onlyUseVersionsFromResolvedFile: false
        )
        let cacheSystem = CacheSystem(
            pinsStore: try descriptionPackage.workspace.pinsStore.load(),
            outputDirectory: frameworkOutputDir,
            storage: nil
        )
        let testingPackage = descriptionPackage
            .graph
            .packages
            .first { $0.manifest.displayName == descriptionPackage.manifest.displayName }!
        let myTarget = testingPackage.modules.first { $0.name == "MyTarget" }!

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
                customFrameworkModuleMapContents: nil
            )
        )

        let cacheKey = try await cacheSystem.calculateCacheKey(of: cacheTarget)

        XCTAssertEqual(cacheKey.pin.description, "1.1.0")
    }
}
