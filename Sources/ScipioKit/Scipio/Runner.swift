import Foundation
import TSCBasic
import Logging

public struct Runner {
    private let fileSystem: any FileSystem

    public init(fileSystem: FileSystem = localFileSystem) {
        LoggingSystem.bootstrap(StreamLogHandler.standardError)
        self.fileSystem = fileSystem
    }

    public func run(packageDirectory: URL, frameworkOutputDir: URL) async throws {
        let package = try Package(packageDirectory: packageDirectory)

        try fileSystem.createDirectory(package.workspaceDirectory, recursive: true)

        let resolver = Resolver(package: package)
        try await resolver.resolve()

        let generator = ProjectGenerator()

        let outputDir = AbsolutePath(frameworkOutputDir.path)

        try generator.generate(for: package)
        let compiler = Compiler<ProcessExecutor>(package: package,
                                                 fileSystem: fileSystem)
        try await compiler.build(outputDir: outputDir)
    }
}
