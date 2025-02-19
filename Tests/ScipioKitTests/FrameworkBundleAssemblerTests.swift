import Foundation
@testable import ScipioKit
import Testing
import Basics

private let fixturesPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources")
    .appendingPathComponent("Fixtures")

@Suite(.serialized)
struct FrameworkBundleAssemblerTests {
    let fileSystem = localFileSystem
    let temporaryDirectory: TSCAbsolutePath

    init() throws {
        self.temporaryDirectory = try fileSystem
            .tempDirectory
            .appending(components: "FrameworkBundleAssemblerTests")
    }

    @Test
    func copyHeaders_keepPublicHeadersStructure_is_false() throws {
        let outputDirectory = temporaryDirectory.appending(component: #function)
        defer { try? fileSystem.removeFileTree(outputDirectory) }

        try assembleFramework(keepPublicHeadersStructure: false, outputDirectory: outputDirectory)

        let frameworkHeadersPath = outputDirectory.appending(components: "Foo.framework", "Headers")
        #expect(Set(try fileSystem.getDirectoryContents(frameworkHeadersPath)) == ["foo.h", "bar.h"])
    }

    @Test
    func copyHeaders_keepPublicHeadersStructure_is_true() throws {
        let outputDirectory = temporaryDirectory.appending(component: #function)
        defer { try? fileSystem.removeFileTree(outputDirectory) }

        try assembleFramework(keepPublicHeadersStructure: true, outputDirectory: outputDirectory)

        let frameworkHeadersPath = outputDirectory.appending(components: "Foo.framework", "Headers")
        #expect(Set(try fileSystem.getDirectoryContents(frameworkHeadersPath)) == ["foo", "bar"])
        #expect(Set(try fileSystem.getDirectoryContents(frameworkHeadersPath.appending(component: "foo"))) == ["foo.h"])
        #expect(Set(try fileSystem.getDirectoryContents(frameworkHeadersPath.appending(component: "bar"))) == ["bar.h"])
    }

    private func assembleFramework(keepPublicHeadersStructure: Bool, outputDirectory: TSCAbsolutePath) throws {
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
        try assembler.assemble()
    }
}
