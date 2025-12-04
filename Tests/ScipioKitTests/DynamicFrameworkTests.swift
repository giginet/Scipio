import Foundation
import Testing
@testable @_spi(Internals) import ScipioKit

private let fixturePath = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .appending(components: "Resources", "Fixtures")

@Suite(.serialized)
struct DynamicFrameworkTests {
    private let fileManager: FileManager = .default

    @Test(
        arguments: [FrameworkType.dynamic, .mergeable]
    )
    func otherLDFlags(frameworkType: FrameworkType) async throws {
        let packageName = "DynamicFrameworkOtherLDFlagsTestPackage"

        let outputDir = fileManager.temporaryDirectory
            .appending(components: "Scipio", packageName)

        defer {
            _ = try? FileManager.default.removeItem(atPath: outputDir.path)
        }

        try await buildPackage(
            packageName: packageName,
            buildOptionsMatrix: [
                "UsableFromInlinePackage": .init(frameworkType: frameworkType),
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
                frameworkCachePolicies: .disabled,
                overwrite: true,
                verbose: false
            )
        )
        let packageDir = fixturePath.appending(component: packageName)

        try await runner.run(
            packageDirectory: packageDir,
            frameworkOutputDir: .custom(outputDir)
        )
    }

    private func checkPlatformDependentLibraries(
        framework: Framework,
        dependencies: [String: Set<Destination>],
        outputDir: URL,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let xcFrameworkPath = outputDir.appending(component: framework.xcFrameworkName)

        let executor = ProcessExecutor()

        for destination in Destination.allCases {
            let binaryPath = xcFrameworkPath.appending(
                components: destination.rawValue, "\(framework.name).framework", framework.name
            )

            let executionResult = try await executor.execute("/usr/bin/otool", "-l", binaryPath.path(percentEncoded: false))
            let loadCommands = try executionResult.unwrapOutput()

            for (dependencyName, destinations) in dependencies {
                let shouldContain = destinations.contains(destination)
                #expect(
                    loadCommands.contains(dependencyName) == shouldContain,
                    "\(dependencyName) \(shouldContain ? "must" : "must NOT") be linked to \(framework.name) for \(destination)."
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
