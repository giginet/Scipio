import Foundation
@testable import ScipioKit
import Testing
import TSCBasic

private let fixturesPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources")
    .appendingPathComponent("Fixtures")

struct FrameworkBundleAssemblerTests {
    let fileSystem = localFileSystem
    let temporaryDirectory: AbsolutePath

    init() throws {
        self.temporaryDirectory = try fileSystem
            .tempDirectory
            .appending(components: "FrameworkBundleAssemblerTests")
    }

    @Test
    func copyHeaders_keepPublicHeadersStructure_is_false() throws {
        let outputDirectory = temporaryDirectory.appending(component: #function)
        try fileSystem.removeFileTree(outputDirectory)

        try assembleFramework(keepPublicHeadersStructure: false, outputDirectory: outputDirectory)

        let frameworkHeadersPath = outputDirectory.appending(components: "Foo.framework", "Headers")
        #expect(Set(try fileSystem.getDirectoryContents(frameworkHeadersPath)) == ["foo.h", "bar.h"])
    }

    @Test
    func copyHeaders_keepPublicHeadersStructure_is_true() throws {
        let outputDirectory = temporaryDirectory.appending(component: #function)
        try fileSystem.removeFileTree(outputDirectory)

        try assembleFramework(keepPublicHeadersStructure: true, outputDirectory: outputDirectory)

        let frameworkHeadersPath = outputDirectory.appending(components: "Foo.framework", "Headers")
        #expect(Set(try fileSystem.getDirectoryContents(frameworkHeadersPath)) == ["foo", "bar"])
        #expect(Set(try fileSystem.getDirectoryContents(frameworkHeadersPath.appending(component: "foo"))) == ["foo.h"])
        #expect(Set(try fileSystem.getDirectoryContents(frameworkHeadersPath.appending(component: "bar"))) == ["bar.h"])
    }

    private func assembleFramework(keepPublicHeadersStructure: Bool, outputDirectory: AbsolutePath) throws {
        let fixture = fixturesPath.appendingPathComponent("FrameworkBundleAssemblerTests").absolutePath
        let frameworkComponents = FrameworkComponents(
            frameworkName: "Foo",
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
