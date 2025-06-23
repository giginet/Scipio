import Foundation
@testable import ScipioKit
import Testing
import TSCBasic

private let fixturesPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources")
    .appendingPathComponent("Fixtures")

@Suite(.serialized)
struct FrameworkBundleAssemblerTests {
    let fileSystem = LocalFileSystem.default
    let temporaryDirectory: AbsolutePath

    init() {
        self.temporaryDirectory = fileSystem
            .tempDirectory
            .appending(components: "FrameworkBundleAssemblerTests")
            .absolutePath
    }

    @Test
    func copyHeaders_keepPublicHeadersStructure_is_false() async throws {
        let outputDirectory = temporaryDirectory.appending(component: #function)
        defer { try? FileManager.default.removeItem(at: outputDirectory.asURL) }

        try await assembleFramework(keepPublicHeadersStructure: false, outputDirectory: outputDirectory)

        let frameworkHeadersPath = outputDirectory.appending(components: "Foo.framework", "Headers")
        #expect(Set(try await fileSystem.getDirectoryContents(frameworkHeadersPath.asURL)) == ["foo.h", "bar.h"])
    }

    @Test
    func copyHeaders_keepPublicHeadersStructure_is_true() async throws {
        let outputDirectory = temporaryDirectory.appending(component: #function)
        defer { try? FileManager.default.removeItem(at: outputDirectory.asURL) }

        try await assembleFramework(keepPublicHeadersStructure: true, outputDirectory: outputDirectory)

        let frameworkHeadersPath = outputDirectory.appending(components: "Foo.framework", "Headers")
        #expect(Set(try await fileSystem.getDirectoryContents(frameworkHeadersPath.asURL)) == ["foo", "bar"])
        #expect(Set(try await fileSystem.getDirectoryContents(frameworkHeadersPath.appending(component: "foo").asURL)) == ["foo.h"])
        #expect(Set(try await fileSystem.getDirectoryContents(frameworkHeadersPath.appending(component: "bar").asURL)) == ["bar.h"])
    }

    private func assembleFramework(keepPublicHeadersStructure: Bool, outputDirectory: AbsolutePath) async throws {
        let fixture = fixturesPath.appendingPathComponent("FrameworkBundleAssemblerTests").absolutePath
        let frameworkComponents = FrameworkComponents(
            isVersionedBundle: false,
            frameworkName: "Foo",
            frameworkPath: fixture.appending(component: "Foo.framework"),
            binaryPath: fixture.appending(components: "Foo.framework", "Foo"),
            infoPlistPath: fixture.appending(components: "Foo.framework", "Info.plist"),
            includeDir: fixture.appending(components: "include"),
            publicHeaderPaths: [
                fixture.appending(components: "include", "foo", "foo.h"),
                fixture.appending(components: "include", "bar", "bar.h"),
            ]
        )
        let assembler = FrameworkBundleAssembler(
            frameworkComponents: frameworkComponents,
            keepPublicHeadersStructure: keepPublicHeadersStructure,
            outputDirectory: outputDirectory,
            fileSystem: fileSystem
        )
        try await assembler.assemble()
    }
}
