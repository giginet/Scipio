import Foundation
import Testing
@testable import ScipioKit

private let fixturePath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources")
    .appendingPathComponent("Fixtures")

@Suite(.serialized)
struct DynamicFrameworkTests {
    private let fileManager: FileManager = .default

    @Test
    func otherLDFlags() async throws {
        let packageName = "DynamicFrameworkOtherLDFlagsTestPackage"

        let outputDir = fileManager.temporaryDirectory
            .appendingPathComponent("Scipio")
            .appendingPathComponent(packageName)

        defer {
            print("remove output directory: \(outputDir.path)")
            _ = try? FileManager.default.removeItem(atPath: outputDir.path)
        }

        try await buildPackage(
            packageName: packageName,
            buildOptionsMatrix: [
                "UsableFromInlinePackage": .init(frameworkType: .dynamic),
            ],
            outputDir: outputDir
        )

        try await checkPlatformDependentLibraries(
            framework: .init(
                name: "UsableFromInlinePackage",
                destinations: [.iOS, .macOS]
            ),
            dependencies: [
                "ClangModule": [.iOS, .macOS],
                "ClangModuleForIOS": [.iOS],
                "ClangModuleForMacOS": [.macOS],
            ],
            outputDir: outputDir
        )
    }

    private func buildPackage(
        packageName: String,
        buildOptionsMatrix: [String: Runner.Options.TargetBuildOptions],
        outputDir: URL
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
        let packageDir = fixturePath.appendingPathComponent(packageName)

        try await runner.run(
            packageDirectory: packageDir,
            frameworkOutputDir: .custom(outputDir)
        )
    }

    private func checkPlatformDependentLibraries(
        framework: Framework,
        dependencies: [String: Set<Destination>],
        outputDir: URL
    ) async throws {
        let xcFrameworkPath = outputDir.appendingPathComponent(framework.xcFrameworkName)

        let executor = ProcessExecutor()

        for arch in Destination.allCases {
            let binaryPath = xcFrameworkPath
                .appendingPathComponent(arch.rawValue)
                .appendingPathComponent("\(framework.name).framework")
                .appendingPathComponent(framework.name)

            let executionResult = try await executor.execute("/usr/bin/otool", "-l", binaryPath.path())
            let loadCommands = try executionResult.unwrapOutput()

            for (dependencyName, destinations) in dependencies {
                #expect(
                    loadCommands.contains(dependencyName) == destinations.contains(arch)
                )
            }
        }
    }

    private struct Framework {
        var name: String
        var destinations: Set<Destination>

        var xcFrameworkName: String {
            "\(name).xcframework"
        }
    }

    private enum Destination: String, CaseIterable {
        case iOS = "ios-arm64"
        case macOS = "macos-arm64_x86_64"
    }
}
