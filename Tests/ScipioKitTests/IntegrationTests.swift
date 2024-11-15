import Foundation
import XCTest
@testable import ScipioKit
import Logging

private let fixturePath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources")
    .appendingPathComponent("Fixtures")

final class IntegrationTests: XCTestCase {
    private let fileManager: FileManager = .default

    static var integrationTestsEnabled: Bool {
        if let value = ProcessInfo.processInfo.environment["ENABLE_INTEGRATION_TESTS"], !value.isEmpty {
            return true
        }
        return false
    }

    override func setUp() async throws {
        try XCTSkipUnless(Self.integrationTestsEnabled)

        try await super.setUp()
    }

    private enum Destination: String {
        case iOS = "ios-arm64"
        case iOSSimulator = "ios-arm64_x86_64-simulator"
        case macOS = "macos-arm64_x86_64"
        case watchOS = "watchos-arm64_arm64_32_armv7k"
    }

    func testMajorPackages() async throws {
        try await testBuildPackages(
            packageName: "IntegrationTestPackage",
            buildOptionsMatrix: [
                "Atomics": .init(frameworkType: .static),
                "_AtomicsShims": .init(frameworkType: .static),
                "Logging": .init(platforms: .specific([.iOS, .watchOS])),
                "NIO": .init(platforms: .specific([.iOS]), frameworkType: .static),
                "SDWebImage": .init(platforms: .specific([.iOS]), isSimulatorSupported: true, isDebugSymbolsEmbedded: true, frameworkType: .dynamic),
            ],
            testCases: [
                ("Atomics", .static, [.iOS], false),
                ("Logging", .static, [.iOS, .watchOS], false),
                ("OrderedCollections", .static, [.iOS], false),
                ("DequeModule", .static, [.iOS], false),
                ("_AtomicsShims", .static, [.iOS], true),
                ("SDWebImage", .dynamic, [.iOS, .iOSSimulator], true),
                ("SDWebImageMapKit", .static, [.iOS], true),
                ("NIO", .static, [.iOS], false),
                ("NIOEmbedded", .static, [.iOS], false),
                ("NIOPosix", .static, [.iOS], false),
                ("NIOCore", .static, [.iOS], false),
                ("NIOConcurrencyHelpers", .static, [.iOS], false),
                ("_NIODataStructures", .static, [.iOS], false),
                ("CNIOAtomics", .static, [.iOS], true),
                ("CNIOLinux", .static, [.iOS], true),
                ("CNIODarwin", .static, [.iOS], true),
                ("CNIOWindows", .static, [.iOS], true),
            ]
        )
    }

    func testMajorMacPackages() async throws {
        try await testBuildPackages(
            packageName: "IntegrationMacTestPackage",
            buildOptionsMatrix: [:],
            testCases: [
                ("Atomics", .static, [.macOS], false),
                ("CNIOAtomics", .static, [.macOS], true),
                ("CNIOBoringSSL", .static, [.macOS], true),
                ("CNIOBoringSSLShims", .static, [.macOS], true),
                ("CNIODarwin", .static, [.macOS], true),
                ("CNIOLinux", .static, [.macOS], true),
                ("CNIOWindows", .static, [.macOS], true),
                ("DequeModule", .static, [.macOS], false),
                ("NIO", .static, [.macOS], false),
                ("NIOConcurrencyHelpers", .static, [.macOS], false),
                ("NIOCore", .static, [.macOS], false),
                ("NIOEmbedded", .static, [.macOS], false),
                ("NIOPosix", .static, [.macOS], false),
                ("NIOSSL", .static, [.macOS], false),
                ("NIOTLS", .static, [.macOS], false),
                ("_AtomicsShims", .static, [.macOS], true),
                ("_NIODataStructures", .static, [.macOS], false),
            ]
        )
    }

    private typealias TestCase = (String, FrameworkType, Set<Destination>, Bool)

    private func testBuildPackages(
        packageName: String,
        buildOptionsMatrix: [String: Runner.Options.TargetBuildOptions],
        testCases: [TestCase]
    ) async throws {
        let runner = Runner(
            mode: .prepareDependencies,
            options: .init(
                baseBuildOptions: .init(
                    buildConfiguration: .release,
                    isSimulatorSupported: false,
                    isDebugSymbolsEmbedded: false,
                    frameworkType: .static,
                    enableLibraryEvolution: false
                ),
                buildOptionsMatrix: buildOptionsMatrix,
                shouldOnlyUseVersionsFromResolvedFile: true,
                cachePolicies: .disabled,
                overwrite: true,
                verbose: false
            )
        )
        let outputDir = fileManager.temporaryDirectory
            .appendingPathComponent("Scipio")
            .appendingPathComponent(packageName)
        let packageDir = fixturePath.appendingPathComponent(packageName)
        print("package directory: \(packageDir.path)")
        print("output directory: \(outputDir.path)")

        try await runner.run(
            packageDirectory: packageDir,
            frameworkOutputDir: .custom(outputDir)
        )
        addTeardownBlock {
            print("remove output directory: \(outputDir.path)")
            try FileManager.default.removeItem(atPath: outputDir.path)
        }

        let outputDirContents = try fileManager.contentsOfDirectory(atPath: outputDir.path)
        let allExpectedFrameworkNames = testCases.map { "\($0.0).xcframework" }
        XCTAssertEqual(
            outputDirContents.sorted(),
            allExpectedFrameworkNames.sorted(),
            "Expected frameworks should be generated"
        )

        for (frameworkName, frameworkType, platforms, isClangFramework) in testCases {
            let xcFrameworkName = "\(frameworkName).xcframework"
            XCTAssertTrue(
                outputDirContents.contains(xcFrameworkName),
                "\(xcFrameworkName) should be built"
            )

            let expectedDestinations = platforms.map(\.rawValue).sorted()

            let xcFrameworkPath = outputDir
                .appendingPathComponent(xcFrameworkName)

            XCTAssertEqual(
                try fileManager.contentsOfDirectory(atPath: xcFrameworkPath.path)
                    .filter { $0 != "Info.plist" }.sorted(),
                expectedDestinations,
                "\(xcFrameworkName) must contain platforms that are equal to \(expectedDestinations.joined(separator: ", "))"
            )

            for destination in expectedDestinations {
                let sdkRoot = xcFrameworkPath
                    .appendingPathComponent(destination)

                if let buildOption = buildOptionsMatrix[frameworkName],
                   buildOption.isDebugSymbolsEmbedded == true,
                   buildOption.frameworkType == .dynamic {
                    XCTAssertTrue(
                        fileManager.fileExists(atPath: sdkRoot
                            .appendingPathComponent("dSYMs/\(frameworkName).framework.dSYM/Contents/Info.plist").path),
                        "\(xcFrameworkName) should contain a Info.plist file in dSYMs directory"
                    )
                    XCTAssertTrue(
                        fileManager.fileExists(atPath: sdkRoot
                            .appendingPathComponent("dSYMs/\(frameworkName).framework.dSYM/Contents/Resources/DWARF/\(frameworkName)").path),
                        "\(xcFrameworkName) should contain a DWARF file in dSYMs directory"
                    )
                } else {
                    XCTAssertFalse(
                        fileManager.fileExists(atPath: sdkRoot.appendingPathComponent("dSYMs").path),
                        "\(xcFrameworkName) should not contain a dSYMs directory"
                    )
                }

                let frameworkRoot = sdkRoot
                    .appendingPathComponent("\(frameworkName).framework")

                if isClangFramework {
                    XCTAssertTrue(
                        fileManager.fileExists(atPath: frameworkRoot.appendingPathComponent("Headers/\(frameworkName).h").path),
                        "\(xcFrameworkName) should contain an umbrella header"
                    )
                } else {
                    XCTAssertTrue(
                        fileManager.fileExists(atPath: frameworkRoot.appendingPathComponent("Headers/\(frameworkName)-Swift.h").path),
                        "\(xcFrameworkName) should contain a bridging header"
                    )

                    XCTAssertTrue(
                        fileManager.fileExists(atPath: frameworkRoot.appendingPathComponent("Modules/\(frameworkName).swiftmodule").path),
                        "\(xcFrameworkName) should contain swiftmodules"
                    )
                }

                XCTAssertTrue(
                    fileManager.fileExists(atPath: frameworkRoot.appendingPathComponent("Modules/module.modulemap").path),
                    "\(xcFrameworkName) should contain a module map"
                )

                let binaryPath = frameworkRoot.appendingPathComponent(frameworkName)
                XCTAssertTrue(
                    fileManager.fileExists(atPath: binaryPath.path),
                    "\(xcFrameworkName) should contain a binary"
                )

                let actualFrameworkType = try await detectFrameworkType(of: binaryPath)
                XCTAssertEqual(
                    actualFrameworkType,
                    frameworkType,
                    "\(xcFrameworkName) must be a \(frameworkType.rawValue) framework"
                )
            }
        }
    }
}
