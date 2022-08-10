import Foundation
import TSCBasic
import Logging

public struct Runner {
    private let options: Options
    private let fileSystem: any FileSystem

    public struct Options {
        public init(buildOptions: BuildOptions, packageDirectory: URL, outputDirectory: URL? = nil, isCacheEnabled: Bool, force: Bool, verbose: Bool) {
            self.buildOptions = buildOptions
            self.packageDirectory = packageDirectory
            self.outputDirectory = outputDirectory
            self.isCacheEnabled = isCacheEnabled
            self.force = force
            self.verbose = verbose
        }

        public var buildOptions: BuildOptions
        public var packageDirectory: URL
        public var outputDirectory: URL?
        public var isCacheEnabled: Bool
        public var force: Bool
        public var verbose: Bool
    }

    public init(options: Options, fileSystem: FileSystem = localFileSystem) {
        LoggingSystem.bootstrap(StreamLogHandler.standardError)
        if options.verbose {
            setLogLevel(.trace)
        } else {
            setLogLevel(.info)
        }

        self.options = options
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
        do {
            let package = try Package(packageDirectory: resolveURL(packageDirectory))

            try fileSystem.createDirectory(package.workspaceDirectory, recursive: true)

            let resolver = Resolver(package: package)
            try await resolver.resolve()

            let generator = ProjectGenerator()
            try generator.generate(for: package, embedDebugSymbols: options.buildOptions.isDebugSymbolsEmbedded)

            let outputDir: AbsolutePath
            if let dir = frameworkOutputDir {
                outputDir = AbsolutePath(dir.path)
            } else {
                outputDir = AbsolutePath(packageDirectory.path).appending(component: "XCFrameworks")
            }
            let compiler = Compiler<ProcessExecutor>(package: package,
                                                     fileSystem: fileSystem)
            try await compiler.build(
                buildOptions: options.buildOptions,
                outputDir: outputDir,
                isCacheEnabled: options.isCacheEnabled,
                force: options.force
            )
        } catch {
            logger.error("Something went wrong to generate XCFramework")
            logger.error("Please execute with --verbose option.")
        }
    }
}
