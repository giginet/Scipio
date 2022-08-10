import Foundation
import TSCBasic
import Logging

public struct Runner {
    private let configuration: Configuration
    private let fileSystem: any FileSystem

    public struct Configuration {
        public init(tag: String? = nil, packageDirectory: URL, outputDirectory: URL?, buildConfiguration: BuildConfiguration, targetSDKs: Set<SDK>, isCacheEnabled: Bool, isDebugSymbolEmbedded: Bool, force: Bool, verbose: Bool) {
            self.tag = tag
            self.packageDirectory = packageDirectory
            self.outputDirectory = outputDirectory
            self.buildConfiguration = buildConfiguration
            self.targetSDKs = targetSDKs
            self.isCacheEnabled = isCacheEnabled
            self.isDebugSymbolEmbedded = isDebugSymbolEmbedded
            self.force = force
            self.verbose = verbose
        }

        public var tag: String?
        public var packageDirectory: URL
        public var outputDirectory: URL?
        public var buildConfiguration: BuildConfiguration
        public var targetSDKs: Set<SDK>
        public var isCacheEnabled: Bool
        public var isDebugSymbolEmbedded: Bool
        public var force: Bool
        public var verbose: Bool
    }

    public init(configuration: Configuration, fileSystem: FileSystem = localFileSystem) {
        LoggingSystem.bootstrap(StreamLogHandler.standardError)
        self.configuration = configuration
        self.fileSystem = fileSystem
    }

    private func resolveURL(_ fileURL: URL) -> AbsolutePath {
        if fileURL.path.hasPrefix("/") {
            return AbsolutePath(fileURL.path)
        } else if let cd = fileSystem.currentWorkingDirectory {
            return cd.appending(RelativePath(fileURL.path))
        } else {
            return AbsolutePath(fileURL.path)
        }
    }

    public func run(packageDirectory: URL, frameworkOutputDir: URL? = nil) async throws {
        let package = try Package(packageDirectory: resolveURL(packageDirectory))

        try fileSystem.createDirectory(package.workspaceDirectory, recursive: true)

        let resolver = Resolver(package: package)
        try await resolver.resolve()

        let generator = ProjectGenerator()
        try generator.generate(for: package)

        let outputDir: AbsolutePath
        if let dir = frameworkOutputDir {
            outputDir = AbsolutePath(dir.path)
        } else {
            outputDir = AbsolutePath(packageDirectory.path).appending(component: "XCFrameworks")
        }
        let compiler = Compiler<ProcessExecutor>(package: package,
                                                 fileSystem: fileSystem)
        try await compiler.build(outputDir: outputDir)
    }
}
