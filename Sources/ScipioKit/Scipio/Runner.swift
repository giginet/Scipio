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

        let generator = ProjectGenerator(outputDirectory: package.workspaceDirectory)

        let outputDir = AbsolutePath(frameworkOutputDir.path)

        let generationResult = try generator.generate(for: package)
        let compiler = Compiler<ProcessExecutor>(package: package,
                                                 projectPath: generationResult.projectPath,
                                                 fileSystem: fileSystem)
        try await compiler.build(outputDir: outputDir)
    }
}
