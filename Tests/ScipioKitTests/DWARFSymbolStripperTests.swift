import Foundation
import Testing
@testable import ScipioKit

@Suite(.serialized)
struct DWARFSymbolStripperTests {
    private let clangPackagePath = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .appending(components: "Resources", "Fixtures", "ClangPackage")
    private var frameworkOutputDir: URL {
        fileManager.temporaryDirectory.appending(components: "me.giginet.Scipio", "XCFrameworks")
    }
    private let fileManager: FileManager = .default

    @Test("can strip DWARF symbols")
    func canStripDWARFSymbols() async throws {
        defer { try? fileManager.removeItem(at: frameworkOutputDir) }
        let runner = Runner(
            mode: .createPackage,
            options: .init(
                baseBuildOptions: .init(
                    buildConfiguration: .debug,
                    frameworkType: .static,
                    stripStaticDWARFSymbols: true
                )
            )
        )
        try await runner.run(
            packageDirectory: clangPackagePath,
            frameworkOutputDir: .custom(frameworkOutputDir)
        )

        let binaryPath = frameworkOutputDir.appending(
            components: "some_lib.xcframework", "ios-arm64", "some_lib.framework", "some_lib"
        ).path(percentEncoded: false)
        #expect(fileManager.fileExists(atPath: binaryPath))

        let executor = ProcessExecutor()
        let dwarfDumpExecutionResult = try await executor.execute(
            "/usr/bin/xcrun", "dwarfdump", "--debug-info", binaryPath
        )
        let output = try dwarfDumpExecutionResult
            .unwrapOutput()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(output.contains(/\.debug_info\scontents:$/), "The built binary should have empty debug_info section")
        #expect(!output.contains(/\.pcm/), "PCM path should not contain .pcm files")
    }
}
