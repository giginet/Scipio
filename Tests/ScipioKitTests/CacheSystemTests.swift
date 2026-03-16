import Foundation
import Testing
@testable @_spi(Internals) import ScipioKit
@testable import ScipioKitCore

private let fixturePath = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .appending(components: "Resources", "Fixtures")

@Suite(.serialized)
struct CacheSystemTests {
    private let customModuleMap = """
    framework module MyTarget {
        umbrella header "umbrella.h"
        export *
    }
    """

    @Test("encodes cache key to JSON correctly")
    func encodeCacheKey() throws {
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
        let rawString = String(decoding: data, as: UTF8.self)

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
        #expect(rawString == expected)
    }

    @Test("generates different cache keys for remote and local packages", .temporaryDirectory)
    func cacheKeyForRemoteAndLocalPackageDifference() async throws {
        let fileSystem: LocalFileSystem = .default
        let tempDir = TemporaryDirectory.url

        let tempCacheKeyTestsDir = tempDir.appending(component: "CacheKeyTests")
        try fileSystem.copy(
            from: fixturePath.appending(component: "CacheKeyTests"),
            to: tempCacheKeyTestsDir
        )

        // For local package consumption
        let executor = ProcessExecutor()
        _ = try await executor.execute([
            "/usr/bin/xcrun",
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
                packageDirectory: tempCacheKeyTestsDir.appending(component: fixture),
                mode: .createPackage,
                resolvedPackagesCachePolicies: [],
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

        #expect(scipioTestingRemote.localPackageCanonicalLocation == nil)
        #expect(
            scipioTestingLocal.localPackageCanonicalLocation ==
            CanonicalPackageLocation(
                tempDir.appending(component: "scipio-testing")
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .path(percentEncoded: false)
            ).description
        )
        #expect(scipioTestingRemote.targetName == scipioTestingLocal.targetName)
        #expect(scipioTestingRemote.pin == scipioTestingLocal.pin)
    }

    @Test("calculates cache key for root package target", .temporaryDirectory)
    func cacheKeyCalculationForRootPackageTarget() async throws {
        let fileSystem: LocalFileSystem = .default
        let testingPackagePath = fixturePath.appendingPathComponent("TestingPackage")
        let tempTestingPackagePath = TemporaryDirectory.url.appending(component: "TestingPackage")

        try fileSystem.copy(from: testingPackagePath, to: tempTestingPackagePath)

        let descriptionPackage = try await DescriptionPackage(
            packageDirectory: tempTestingPackagePath,
            mode: .createPackage,
            resolvedPackagesCachePolicies: [],
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
        await #expect(throws: CacheSystem.Error.self) {
            _ = try await cacheSystem.calculateCacheKey(of: cacheTarget)
        }

        // Ensure that the cache key is properly calculated when the package is in a repository with the correct tag."
        let processExecutor: Executor = ProcessExecutor()
        let tempTestingPackagePathString = tempTestingPackagePath.path(percentEncoded: false)
        try await processExecutor.execute(["/usr/bin/xcrun", "git", "init", tempTestingPackagePathString])
        try await processExecutor.execute([
            "/usr/bin/xcrun",
            "git",
            "-C",
            tempTestingPackagePathString,
            "add",
            tempTestingPackagePathString,
        ])
        try await processExecutor.execute(["/usr/bin/xcrun", "git", "-C", tempTestingPackagePathString, "commit", "-m", "Initial commit"])
        try await processExecutor.execute(["/usr/bin/xcrun", "git", "-C", tempTestingPackagePathString, "tag", "v1.1"])

        let cacheKey = try await cacheSystem.calculateCacheKey(of: cacheTarget)

        #expect(cacheKey.targetName == myTarget.name)
        #expect(cacheKey.pin.version == "1.1.0")
    }
}
