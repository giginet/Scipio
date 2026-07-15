import Foundation
@testable @_spi(Internals) import ScipioKit
@testable import ScipioKitCore
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
            xcodeVersion: .init(xcodeVersion: "15.4", xcodeBuildVersion: "15F31d"),
            dependencyCacheKeyChecksums: [
                .init(targetName: "Zebra", checksum: "222222"),
                .init(targetName: "Base", checksum: "111111"),
            ]
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
          "dependencyCacheKeyChecksums" : [
            {
              "checksum" : "111111",
              "targetName" : "Base"
            },
            {
              "checksum" : "222222",
              "targetName" : "Zebra"
            }
          ],
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

    func testDecodeAndEncodeCacheKeyWithoutDependencyCacheKeyChecksums() throws {
        let rawString = """
        {
          "buildOptions" : {
            "buildConfiguration" : "release",
            "enableLibraryEvolution" : false,
            "frameworkType" : "dynamic",
            "isDebugSymbolsEmbedded" : false,
            "keepPublicHeadersStructure" : false,
            "sdks" : [
              "iOS"
            ],
            "stripStaticDWARFSymbols" : false
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

        let cacheKey = try JSONDecoder().decode(SwiftPMCacheKey.self, from: Data(rawString.utf8))

        XCTAssertEqual(cacheKey.dependencyCacheKeyChecksums, [])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        XCTAssertEqual(try encoder.encode(cacheKey), Data(rawString.utf8))
    }

    func testCacheKeysIncludeDirectDependencyChecksums() async throws {
        let taggedFixture = try await makeTaggedPartialCacheTestPackagePath()
        defer { try? LocalFileSystem.default.removeFileTree(taggedFixture.rootPath) }

        let descriptionPackage = try await DescriptionPackage(
            packageDirectory: taggedFixture.packagePath,
            mode: .createPackage,
            resolvedPackagesCachePolicies: [],
            onlyUseVersionsFromResolvedFile: true
        )
        let buildOptions = defaultBuildOptions()
        let targetGraph = try descriptionPackage.resolveBuildProductDependencyGraph().map { buildProduct in
            CacheSystem.CacheTarget(buildProduct: buildProduct, buildOptions: buildOptions)
        }
        let cacheSystem = CacheSystem(
            outputDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("XCFrameworks")
        )

        let cacheKeys = try await cacheSystem.calculateCacheKeys(for: targetGraph)
        let baseTarget = try XCTUnwrap(targetGraph.allNodes.map(\.value).first { $0.buildProduct.target.name == "Base" })
        let badTarget = try XCTUnwrap(targetGraph.allNodes.map(\.value).first { $0.buildProduct.target.name == "Bad" })
        let baseCacheKey = try XCTUnwrap(cacheKeys[baseTarget])
        let badCacheKey = try XCTUnwrap(cacheKeys[badTarget])

        XCTAssertEqual(baseCacheKey.dependencyCacheKeyChecksums, [])
        XCTAssertEqual(
            badCacheKey.dependencyCacheKeyChecksums,
            [
                DependencyCacheKeyChecksum(
                    targetName: "Base",
                    checksum: try baseCacheKey.calculateChecksum()
                ),
            ]
        )
    }

    func testCacheKeysRemainAvailableWhenDependentRevisionIsNotDetected() async throws {
        let taggedFixture = try await makeTaggedPartialCacheTestPackagePath()
        defer { try? LocalFileSystem.default.removeFileTree(taggedFixture.rootPath) }

        let descriptionPackage = try await DescriptionPackage(
            packageDirectory: taggedFixture.packagePath,
            mode: .createPackage,
            resolvedPackagesCachePolicies: [],
            onlyUseVersionsFromResolvedFile: true
        )
        let buildOptions = defaultBuildOptions()
        let targetGraph = try descriptionPackage.resolveBuildProductDependencyGraph().map { buildProduct in
            var package = buildProduct.package
            if buildProduct.target.name == "Bad" {
                package.path = "/path/to/a/missing/package"
            }
            let buildProduct = BuildProduct(package: package, target: buildProduct.target)
            return CacheSystem.CacheTarget(buildProduct: buildProduct, buildOptions: buildOptions)
        }
        let cacheSystem = CacheSystem(
            outputDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("XCFrameworks")
        )

        let cacheKeys = try await cacheSystem.calculateCacheKeys(for: targetGraph)
        let baseTarget = try XCTUnwrap(targetGraph.allNodes.map(\.value).first { $0.buildProduct.target.name == "Base" })
        let badTarget = try XCTUnwrap(targetGraph.allNodes.map(\.value).first { $0.buildProduct.target.name == "Bad" })

        XCTAssertNotNil(cacheKeys[baseTarget])
        XCTAssertNil(cacheKeys[badTarget])
    }

    func testDependencyCacheKeyChangesDependentCacheKey() async throws {
        let taggedFixture = try await makeTaggedPartialCacheTestPackagePath()
        defer { try? LocalFileSystem.default.removeFileTree(taggedFixture.rootPath) }

        let descriptionPackage = try await DescriptionPackage(
            packageDirectory: taggedFixture.packagePath,
            mode: .createPackage,
            resolvedPackagesCachePolicies: [],
            onlyUseVersionsFromResolvedFile: true
        )
        let dynamicBuildOptions = defaultBuildOptions(frameworkType: .dynamic)
        let staticBuildOptions = defaultBuildOptions(frameworkType: .static)
        let dynamicTargetGraph = try descriptionPackage.resolveBuildProductDependencyGraph().map { buildProduct in
            CacheSystem.CacheTarget(buildProduct: buildProduct, buildOptions: dynamicBuildOptions)
        }
        let changedDependencyTargetGraph = try descriptionPackage.resolveBuildProductDependencyGraph().map { buildProduct in
            CacheSystem.CacheTarget(
                buildProduct: buildProduct,
                buildOptions: buildProduct.target.name == "Base" ? staticBuildOptions : dynamicBuildOptions
            )
        }
        let cacheSystem = CacheSystem(
            outputDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("XCFrameworks")
        )

        let dynamicCacheKeys = try await cacheSystem.calculateCacheKeys(for: dynamicTargetGraph)
        let changedDependencyCacheKeys = try await cacheSystem.calculateCacheKeys(for: changedDependencyTargetGraph)
        let dynamicBaseTarget = try XCTUnwrap(dynamicTargetGraph.allNodes.map(\.value).first { $0.buildProduct.target.name == "Base" })
        let dynamicBadTarget = try XCTUnwrap(dynamicTargetGraph.allNodes.map(\.value).first { $0.buildProduct.target.name == "Bad" })
        let changedBaseTarget = try XCTUnwrap(
            changedDependencyTargetGraph.allNodes.map(\.value).first { $0.buildProduct.target.name == "Base" }
        )
        let changedBadTarget = try XCTUnwrap(
            changedDependencyTargetGraph.allNodes.map(\.value).first { $0.buildProduct.target.name == "Bad" }
        )

        XCTAssertNotEqual(
            try dynamicCacheKeys[dynamicBaseTarget]?.calculateChecksum(),
            try changedDependencyCacheKeys[changedBaseTarget]?.calculateChecksum()
        )
        XCTAssertNotEqual(
            try dynamicCacheKeys[dynamicBadTarget]?.calculateChecksum(),
            try changedDependencyCacheKeys[changedBadTarget]?.calculateChecksum()
        )
    }

    func testCacheKeyForRemoteAndLocalPackageDifference() async throws {
        let fileSystem: LocalFileSystem = .default

        let tempDir = fileSystem.tempDirectory.appending(component: #function)
        try fileSystem.removeFileTree(tempDir)
        try fileSystem.createDirectory(tempDir)

        defer { try? fileSystem.removeFileTree(tempDir) }

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
            let cacheKeys = try await calculateCacheKeys(for: cacheTarget, using: cacheSystem)
            return try XCTUnwrap(cacheKeys[cacheTarget])
        }

        let scipioTestingRemote = try await scipioTestingCacheKey(fixture: "AsRemotePackage")
        let scipioTestingLocal = try await scipioTestingCacheKey(fixture: "AsLocalPackage")

        XCTAssertNil(scipioTestingRemote.localPackageCanonicalLocation)
        XCTAssertEqual(
            scipioTestingLocal.localPackageCanonicalLocation,
            CanonicalPackageLocation(
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
        let fileSystem: LocalFileSystem = .default
        let testingPackagePath = fixturePath.appendingPathComponent("TestingPackage")
        let tempTestingPackagePath = fileSystem.tempDirectory.appending(component: "temp_TestingPackage")

        try fileSystem.removeFileTree(tempTestingPackagePath)
        try fileSystem.copy(from: testingPackagePath, to: tempTestingPackagePath)

        defer { try? fileSystem.removeFileTree(tempTestingPackagePath) }

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

        // Graph-based calculation excludes targets whose package revision cannot be detected.
        let unavailableCacheKeys = try await calculateCacheKeys(for: cacheTarget, using: cacheSystem)
        XCTAssertNil(unavailableCacheKeys[cacheTarget])

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

        let cacheKeys = try await calculateCacheKeys(for: cacheTarget, using: cacheSystem)
        let cacheKey = try XCTUnwrap(cacheKeys[cacheTarget])

        XCTAssertEqual(cacheKey.targetName, myTarget.name)
        XCTAssertEqual(cacheKey.pin.version, "1.1.0")
    }

    private func calculateCacheKeys(
        for target: CacheSystem.CacheTarget,
        using cacheSystem: CacheSystem
    ) async throws -> [CacheSystem.CacheTarget: SwiftPMCacheKey] {
        let graph = try DependencyGraph.resolve(
            Set([target]),
            id: \.buildProduct.target.name,
            childIDs: { _ in [] }
        )
        return try await cacheSystem.calculateCacheKeys(for: graph)
    }

    private func defaultBuildOptions(frameworkType: FrameworkType = .dynamic) -> BuildOptions {
        BuildOptions(
            buildConfiguration: .release,
            isDebugSymbolsEmbedded: false,
            frameworkType: frameworkType,
            sdks: [.iOS, .iOSSimulator],
            extraFlags: nil,
            extraBuildParameters: nil,
            enableLibraryEvolution: false,
            keepPublicHeadersStructure: false,
            customFrameworkModuleMapContents: nil,
            stripStaticDWARFSymbols: false
        )
    }

    private func makeTaggedPartialCacheTestPackagePath(
        function: String = #function
    ) async throws -> (rootPath: URL, packagePath: URL) {
        let fileSystem: LocalFileSystem = .default
        let rootPath = fileSystem.tempDirectory.appending(component: function)
        let packagePath = rootPath.appending(component: "PartialCacheTestPackage")

        try fileSystem.removeFileTree(rootPath)
        try fileSystem.createDirectory(rootPath)
        try fileSystem.copy(
            from: fixturePath.appendingPathComponent("PartialCacheTestPackage"),
            to: packagePath
        )

        let executor: Executor = ProcessExecutor()
        let packagePathString = packagePath.path(percentEncoded: false)
        try await executor.execute(["/usr/bin/xcrun", "git", "init", packagePathString])
        try await executor.execute(["/usr/bin/xcrun", "git", "-C", packagePathString, "add", "."])
        try await executor.execute([
            "/usr/bin/xcrun",
            "git",
            "-C",
            packagePathString,
            "-c",
            "user.name=Scipio Tests",
            "-c",
            "user.email=scipio@example.com",
            "commit",
            "-m",
            "Initial commit",
        ])
        try await executor.execute(["/usr/bin/xcrun", "git", "-C", packagePathString, "tag", "v1.0.0"])

        return (rootPath, packagePath)
    }
}
