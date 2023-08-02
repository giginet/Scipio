import Foundation
import XCTest
@testable import ScipioKit
import Logging

private let fixturePath = URL(fileURLWithPath: #file)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources")
    .appendingPathComponent("Fixtures")
private let integrationTestPackagePath = fixturePath.appendingPathComponent("IntegrationTestPackage")

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
        case macOS = "macos-arm64_x86_64"
        case watchOS = "watchos-arm64_arm64_32_armv7k"
    }

    func testMajorPackages() async throws {
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
                buildOptionsMatrix: [
                    "Atomics": .init(frameworkType: .static),
                    "_AtomicsShims": .init(frameworkType: .static),
                    "Logging": .init(platforms: .specific([.iOS, .watchOS])),
                    "NIOSSL": .init(platforms: .specific([.macOS]), frameworkType: .static),
                ],
                cacheMode: .disabled,
                overwrite: true,
                verbose: false
            )
        )
        let outputDir = fileManager.temporaryDirectory
            .appendingPathComponent("Scipio")
            .appendingPathComponent("Integration")
        try await runner.run(
            packageDirectory: integrationTestPackagePath,
            frameworkOutputDir: .custom(outputDir)
        )
        addTeardownBlock {
            try self.fileManager.removeItem(atPath: outputDir.path)
        }

        let testCase: [(String, FrameworkType, Set<Destination>, Bool)] = [
            ("Atomics", .static, [.iOS], false),
            ("Logging", .static, [.iOS, .watchOS], false),
            ("OrderedCollections", .static, [.iOS], false),
            ("DequeModule", .static, [.iOS], false),
            ("_AtomicsShims", .static, [.iOS], true),
            ("SDWebImage", .static, [.iOS], true),
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
            ("CNIOBoringSSL", .static, [.macOS], true),
            ("CNIOBoringSSLShims", .static, [.macOS], true),
            ("NIOTLS", .static, [.macOS], false),
            ("NIOSSL", .static, [.macOS], false),
        ]

        let outputDirContents = try fileManager.contentsOfDirectory(atPath: outputDir.path)
        let allExpectedFrameworkNames = testCase.map { "\($0.0).xcframework" }
        XCTAssertEqual(
            Set(outputDirContents),
            Set(allExpectedFrameworkNames),
            "Expected frameworks should be generated"
        )

        for (frameworkName, frameworkType, platforms, isClangFramework) in testCase {
            let xcFrameworkName = "\(frameworkName).xcframework"
            XCTAssertTrue(
                outputDirContents.contains(xcFrameworkName),
                "\(xcFrameworkName) should be built"
            )

            let expectedDestinations = platforms.map(\.rawValue)

            let xcFrameworkPath = outputDir
                .appendingPathComponent(xcFrameworkName)

            XCTAssertTrue(
                Set(try fileManager.contentsOfDirectory(atPath: xcFrameworkPath.path))
                    .isSuperset(of: expectedDestinations),
                "\(xcFrameworkName) must contains \(expectedDestinations.joined(separator: ", "))"
            )

            for destination in expectedDestinations {
                let frameworkRoot = xcFrameworkPath
                    .appendingPathComponent(destination)
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
