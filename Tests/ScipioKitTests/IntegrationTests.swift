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

    private func detectFrameworkType(binaryPath: URL) async throws -> FrameworkType? {
        let executor = ProcessExecutor()
        let result = try await executor.execute("/usr/bin/file", binaryPath.path)
        let output = try XCTUnwrap(try result.unwrapOutput())
        if output.contains("current ar archive") {
            return .static
        } else if output.contains("dynamically linked shared library") {
            return .dynamic
        }
        return nil
    }

    func testMajorPackages() async throws {
        let runner = Runner(
            mode: .prepareDependencies,
            options: .init(
                baseBuildOptions: .init(
                    buildConfiguration: .release,
                    isSimulatorSupported: false,
                    isDebugSymbolsEmbedded: false,
                    frameworkType: .dynamic
                ),
                buildOptionsMatrix: [
                    "Atomics": .init(frameworkType: .static),
                    "_AtomicsShims": .init(frameworkType: .static),
                    "Logging": .init(platforms: .specific([.iOS, .watchOS])),
                ],
                cacheMode: .disabled,
                skipProjectGeneration: false,
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

        let expectedFrameworks = [
            "Atomics",
            "Logging",
            "OrderedCollections",
            "_AtomicsShims",
        ]

        let outputDirContents = try fileManager.contentsOfDirectory(atPath: outputDir.path)

        for frameworkName in expectedFrameworks {
            let xcFrameworkName = "\(frameworkName).xcframework"
            XCTAssertTrue(
                outputDirContents.contains(xcFrameworkName),
                "\(xcFrameworkName) should be built"
            )

            let expectedDestinations: Set<String>

            if frameworkName == "Logging" {
                expectedDestinations = ["ios-arm64", "watchos-arm64_arm64_32_armv7k"]
            } else {
                expectedDestinations = ["ios-arm64"]
            }

            let xcFrameworkPath = outputDir
                .appendingPathComponent(xcFrameworkName)

            XCTAssertEqual(
                Set(try fileManager.contentsOfDirectory(atPath: xcFrameworkPath.path)),
                Set(["Info.plist"]).union(expectedDestinations),
                "\(xcFrameworkName) must contains \(expectedDestinations.joined(separator: ", "))"
            )

            for destination in expectedDestinations {
                let frameworkRoot = xcFrameworkPath
                    .appendingPathComponent(destination)
                    .appendingPathComponent("\(frameworkName).framework")

                let isPrivateFramework = frameworkName.hasPrefix("_")

                if !isPrivateFramework {
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

                let actualFrameworkType = try await detectFrameworkType(binaryPath: binaryPath)
                if ["Atomics", "_AtomicsShims"].contains(frameworkName) { // Static Framework
                    XCTAssertEqual(
                        actualFrameworkType,
                        .static,
                        "\(xcFrameworkName) must be a static framework"
                    )
                } else { // Dynamic Framework
                    XCTAssertEqual(
                        actualFrameworkType,
                        .dynamic,
                        "\(xcFrameworkName) must be a dynamic framework"
                    )
                }
            }
        }
    }
}
