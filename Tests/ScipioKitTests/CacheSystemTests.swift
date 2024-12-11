import Foundation
@testable import ScipioKit
import Testing
import Basics

private let fixturePath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources")
    .appendingPathComponent("Fixtures")

struct CacheSystemTests {

    private let customModuleMap = """
    framework module MyTarget {
        umbrella header "umbrella.h"
        export *
    }
    """

    @Test
    func encodeCacheKey() throws {
        let cacheKey = SwiftPMCacheKey(
            targetName: "MyTarget",
            pin: .revision("111111111"),
            buildOptions: .init(
                buildConfiguration: .release,
                isDebugSymbolsEmbedded: false,
                frameworkType: .dynamic,
                sdks: [.iOS],
                extraFlags: .init(swiftFlags: ["-D", "SOME_FLAG"]),
                extraBuildParameters: ["SWIFT_OPTIMIZATION_LEVEL": "-Osize"],
                enableLibraryEvolution: true,
                keepPublicHeadersStructure: false,
                customFrameworkModuleMapContents: Data(customModuleMap.utf8)
            ),
            clangVersion: "clang-1400.0.29.102",
            xcodeVersion: .init(xcodeVersion: "15.4", xcodeBuildVersion: "15F31d")
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(cacheKey)
        let rawString = try #require(String(decoding: data, as: UTF8.self))

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
        // swiftlint:enable line_length
        #expect(rawString == expected)
    }

    @Test
    func cacheKeyCalculationForRootPackageTarget() async throws {
        let fileSystem = localFileSystem
        let testingPackagePath = fixturePath.appendingPathComponent("TestingPackage")
        let tempTestingPackagePath = try fileSystem.tempDirectory.appending(component: "temp_TestingPackage").scipioAbsolutePath

        try fileSystem.removeFileTree(tempTestingPackagePath)
        try fileSystem.copy(from: testingPackagePath.absolutePath, to: tempTestingPackagePath)

        defer { try? fileSystem.removeFileTree(tempTestingPackagePath) }

        let descriptionPackage = try DescriptionPackage(
            packageDirectory: tempTestingPackagePath,
            mode: .createPackage,
            onlyUseVersionsFromResolvedFile: false
        )
        let cacheSystem = CacheSystem(
            pinsStore: try descriptionPackage.workspace.pinsStore.load(),
            outputDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("XCFrameworks")
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
                keepPublicHeadersStructure: false,
                customFrameworkModuleMapContents: nil
            )
        )

        // Ensure that the cache key cannot be calculated if the package is not in the Git repository.
        try await #require(
            performing: {
                _ = try await cacheSystem.calculateCacheKey(of: cacheTarget)
            },
            throws: { error in
                let error = try #require(error as? CacheSystem.Error)
                return error.errorDescription == "Repository version is not detected for \(descriptionPackage.name)."
            }
        )

        // Ensure that the cache key is properly calculated when the package is in a repository with the correct tag."
        let processExecutor: Executor = ProcessExecutor()
        try await processExecutor.execute(["git", "init", tempTestingPackagePath.pathString])
        try await processExecutor.execute(["git", "-C", tempTestingPackagePath.pathString, "add", tempTestingPackagePath.pathString])
        try await processExecutor.execute(["git", "-C", tempTestingPackagePath.pathString, "commit", "-m", "Initial commit"])
        try await processExecutor.execute(["git", "-C", tempTestingPackagePath.pathString, "tag", "v1.1"])

        let cacheKey = try await cacheSystem.calculateCacheKey(of: cacheTarget)

        #expect(cacheKey.targetName == myTarget.name)
        #expect(cacheKey.pin.description == "1.1.0")
    }
}
