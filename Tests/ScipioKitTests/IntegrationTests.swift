import Foundation
import Testing
@testable import ScipioKit
import Logging

private let fixturePath = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .appending(components: "Resources", "Fixtures")

private var integrationTestsEnabled: Bool {
    if let value = ProcessInfo.processInfo.environment["ENABLE_INTEGRATION_TESTS"], !value.isEmpty {
        return true
    }
    return false
}

@Suite(.serialized)
struct IntegrationTests {
    private let fileManager: FileManager = .default

    private enum Destination: String {
        case iOS = "ios-arm64"
        case iOSSimulator = "ios-arm64_x86_64-simulator"
        case macOS = "macos-arm64_x86_64"
        case watchOS = "watchos-arm64_arm64_32_armv7k"
    }

    @Test("builds major packages with various configurations", .enabled(if: integrationTestsEnabled))
    func majorPackages() async throws {
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
                ("CNIOWASI", .static, [.iOS], true),
                ("InternalCollectionsUtilities", .static, [.iOS], false),
                ("_NIOBase64", .static, [.iOS], false),
            ]
        )
    }

    @Test("builds major Mac packages", .enabled(if: integrationTestsEnabled))
    func majorMacPackages() async throws {
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
                ("CNIOWASI", .static, [.macOS], true),
                ("InternalCollectionsUtilities", .static, [.macOS], false),
                ("_NIOBase64", .static, [.macOS], false),
            ]
        )
    }

    @Test("builds dynamic framework with OTHER_LDFLAGS", .enabled(if: integrationTestsEnabled))
    func dynamicFramework() async throws {
        try await testBuildPackages(
            packageName: "DynamicFrameworkOtherLDFlagsTestPackage",
            buildOptionsMatrix: [
                "UsableFromInlinePackage": .init(frameworkType: .dynamic),
            ],
            testCases: [
                ("UsableFromInlinePackage", .dynamic, [.iOS, .macOS], false),
                ("ClangModule", .static, [.iOS, .macOS], true),
                ("ClangModuleForIOS", .static, [.iOS, .macOS], true),
                ("ClangModuleForMacOS", .static, [.iOS, .macOS], true),
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
                frameworkCachePolicies: .disabled,
                overwrite: true,
                verbose: false
            )
        )
        let outputDir = fileManager.temporaryDirectory
            .appending(components: "Scipio", packageName)
        let packageDir = fixturePath.appending(component: packageName)
        print("package directory: \(packageDir.path(percentEncoded: false))")
        print("output directory: \(outputDir.path(percentEncoded: false))")

        try await runner.run(
            packageDirectory: packageDir,
            frameworkOutputDir: .custom(outputDir)
        )
        defer {
            print("remove output directory: \(outputDir.path(percentEncoded: false))")
            try? fileManager.removeItem(at: outputDir)
        }

        let outputDirContents = try fileManager.contentsOfDirectory(atPath: outputDir.path(percentEncoded: false))
        let allExpectedFrameworkNames = testCases.map { "\($0.0).xcframework" }
        #expect(
            outputDirContents.sorted() == allExpectedFrameworkNames.sorted(),
            "Expected frameworks should be generated"
        )

        for (frameworkName, frameworkType, platforms, isClangFramework) in testCases {
            let xcFrameworkName = "\(frameworkName).xcframework"
            #expect(
                outputDirContents.contains(xcFrameworkName),
                "\(xcFrameworkName) should be built"
            )

            let expectedDestinations = platforms.map(\.rawValue).sorted()

            let xcFrameworkPath = outputDir
                .appending(component: xcFrameworkName)

            #expect(
                try fileManager.contentsOfDirectory(atPath: xcFrameworkPath.path(percentEncoded: false))
                    .filter { $0 != "Info.plist" }.sorted() == expectedDestinations,
                "\(xcFrameworkName) must contain platforms that are equal to \(expectedDestinations.joined(separator: ", "))"
            )

            for destination in expectedDestinations {
                let sdkRoot = xcFrameworkPath
                    .appending(component: destination)

                if let buildOption = buildOptionsMatrix[frameworkName],
                   buildOption.isDebugSymbolsEmbedded == true,
                   buildOption.frameworkType == .dynamic {
                    #expect(
                        fileManager.fileExists(atPath: sdkRoot
                            .appending(components: "dSYMs", "\(frameworkName).framework.dSYM", "Contents", "Info.plist").path(percentEncoded: false)),
                        "\(xcFrameworkName) should contain a Info.plist file in dSYMs directory"
                    )
                    let dwarfPath = sdkRoot
                        .appending(components: "dSYMs", "\(frameworkName).framework.dSYM", "Contents", "Resources", "DWARF", frameworkName)
                        .path(percentEncoded: false)
                    #expect(
                        fileManager.fileExists(atPath: dwarfPath),
                        "\(xcFrameworkName) should contain a DWARF file in dSYMs directory"
                    )
                } else {
                    #expect(
                        !fileManager.fileExists(atPath: sdkRoot.appending(component: "dSYMs").path(percentEncoded: false)),
                        "\(xcFrameworkName) should not contain a dSYMs directory"
                    )
                }

                let frameworkRoot = sdkRoot
                    .appending(component: "\(frameworkName).framework")

                if isClangFramework {
                    let umbrellaHeaderPath = frameworkRoot
                        .appending(components: "Headers", "\(frameworkName).h")
                        .path(percentEncoded: false)
                    #expect(
                        fileManager.fileExists(atPath: umbrellaHeaderPath),
                        "\(xcFrameworkName) should contain an umbrella header"
                    )
                } else {
                    let bridgingHeaderPath = frameworkRoot
                        .appending(components: "Headers", "\(frameworkName)-Swift.h")
                        .path(percentEncoded: false)
                    #expect(
                        fileManager.fileExists(atPath: bridgingHeaderPath),
                        "\(xcFrameworkName) should contain a bridging header"
                    )

                    let swiftmodulePath = frameworkRoot
                        .appending(components: "Modules", "\(frameworkName).swiftmodule")
                        .path(percentEncoded: false)
                    #expect(
                        fileManager.fileExists(atPath: swiftmodulePath),
                        "\(xcFrameworkName) should contain swiftmodules"
                    )
                }

                #expect(
                    fileManager.fileExists(atPath: frameworkRoot.appending(components: "Modules", "module.modulemap").path(percentEncoded: false)),
                    "\(xcFrameworkName) should contain a module map"
                )

                let binaryPath = frameworkRoot.appending(component: frameworkName)
                #expect(
                    fileManager.fileExists(atPath: binaryPath.path(percentEncoded: false)),
                    "\(xcFrameworkName) should contain a binary"
                )

                let actualFrameworkType = try await FrameworkTypeDetector.detect(of: binaryPath)
                #expect(
                    actualFrameworkType == frameworkType,
                    "\(xcFrameworkName) must be a \(frameworkType.rawValue) framework"
                )
            }
        }
    }
}
