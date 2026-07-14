import Foundation
@testable import ScipioKit
import Testing

private let fixturesPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources")
    .appendingPathComponent("Fixtures")

@Suite(.serialized)
struct FrameworkBundleAssemblerTests {
    let fileSystem: LocalFileSystem = .default
    let temporaryDirectory: URL

    init() {
        self.temporaryDirectory = fileSystem
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

    @Test("Flattened header name collisions fail loudly when rewriting")
    func copyHeaders_flattened_name_collision_fails() throws {
        let outputDirectory = temporaryDirectory.appending(component: #function)
        let includeDir = temporaryDirectory.appending(components: "\(#function)-src", "include")
        defer {
            try? fileSystem.removeFileTree(outputDirectory)
            try? fileSystem.removeFileTree(includeDir.parentDirectory)
        }

        for subdirectory in ["foo", "bar"] {
            try fileSystem.writeFileContents(
                includeDir.appending(components: subdirectory, "common.h"),
                string: "// \(subdirectory)\n"
            )
        }

        let fixture = fixturesPath.appendingPathComponent("FrameworkBundleAssemblerTests")
        let frameworkComponents = FrameworkComponents(
            isVersionedBundle: false,
            frameworkName: "Foo",
            frameworkPath: fixture.appending(component: "Foo.framework"),
            binaryPath: fixture.appending(components: "Foo.framework", "Foo"),
            infoPlistPath: fixture.appending(components: "Foo.framework", "Info.plist"),
            includeDir: includeDir,
            publicHeaderPaths: [
                includeDir.appending(components: "foo", "common.h"),
                includeDir.appending(components: "bar", "common.h"),
            ]
        )
        let assembler = FrameworkBundleAssembler(
            frameworkComponents: frameworkComponents,
            keepPublicHeadersStructure: false,
            outputDirectory: outputDirectory,
            fileSystem: fileSystem,
            headerIncludeRewriter: CHeaderIncludeRewriter(replacementsByHeaderPath: ["unrelated.h": "Foo/unrelated.h"])
        )

        let error = #expect(throws: FileSystemError.self) {
            try assembler.assemble()
        }
        guard case .alreadyExistsAtDestination(let path)? = error else {
            Issue.record("Expected alreadyExistsAtDestination, got \(String(describing: error))")
            return
        }
        #expect(path.lastPathComponent == "common.h")
    }

    private func assembleFramework(keepPublicHeadersStructure: Bool, outputDirectory: URL) throws {
        let fixture = fixturesPath.appendingPathComponent("FrameworkBundleAssemblerTests")
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
