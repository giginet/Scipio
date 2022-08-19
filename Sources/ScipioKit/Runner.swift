import Foundation
import TSCBasic

public struct Runner {
    private let options: Options
    private let fileSystem: any FileSystem

    public enum Mode {
        case createPackage
        case prepareDependencies
    }

    public enum Error: Swift.Error, LocalizedError {
        case invalidPackage(AbsolutePath)
        case platformNotSpecified
        case compilerError(Swift.Error)

        public var errorDescription: String? {
            switch self {
            case .platformNotSpecified:
                return "Any platforms are not spcified in Package.swift"
            case .invalidPackage(let path):
                return "Invalid package. \(path.pathString)"
            case .compilerError(let error):
                return "\(error.localizedDescription)"
            }
        }
    }

    public struct Options {
        public init(buildConfiguration: BuildConfiguration, isSimulatorSupported: Bool, isDebugSymbolsEmbedded: Bool, outputDirectory: URL? = nil, isCacheEnabled: Bool, verbose: Bool) {
            self.buildConfiguration = buildConfiguration
            self.isSimulatorSupported = isSimulatorSupported
            self.isDebugSymbolsEmbedded = isDebugSymbolsEmbedded
            self.outputDirectory = outputDirectory
            self.isCacheEnabled = isCacheEnabled
            self.verbose = verbose
        }

        public var buildConfiguration: BuildConfiguration
        public var isSimulatorSupported: Bool
        public var isDebugSymbolsEmbedded: Bool
        public var outputDirectory: URL?
        public var isCacheEnabled: Bool
        public var verbose: Bool
    }
    private var mode: Mode

    public init(mode: Mode, options: Options, fileSystem: FileSystem = localFileSystem) {
        self.mode = mode
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
        let packagePath = resolveURL(packageDirectory)
        let package: Package
        do {
            package = try Package(packageDirectory: packagePath)
        } catch {
            throw Error.invalidPackage(packagePath)
        }

        let sdks = package.supportedSDKs
        guard !sdks.isEmpty else {
            throw Error.platformNotSpecified
        }

        let buildOptions = BuildOptions(buildConfiguration: options.buildConfiguration,
                                        isSimulatorSupported: options.isSimulatorSupported,
                                        isDebugSymbolsEmbedded: options.isDebugSymbolsEmbedded,
                                        sdks: sdks)
        try fileSystem.createDirectory(package.workspaceDirectory, recursive: true)

        let resolver = Resolver(package: package)
        try await resolver.resolve()

        let generator = ProjectGenerator()
        try generator.generate(for: package, embedDebugSymbols: buildOptions.isDebugSymbolsEmbedded)

        let outputDir: AbsolutePath
        if let dir = frameworkOutputDir {
            outputDir = AbsolutePath(dir.path)
        } else {
            outputDir = AbsolutePath(packageDirectory.path).appending(component: "XCFrameworks")
        }
        let compiler = Compiler<ProcessExecutor>(rootPackage: package,
                                                 fileSystem: fileSystem)
        do {
            switch mode {
            case .createPackage:
                try await compiler.build(
                    mode: .createPackage,
                    buildOptions: buildOptions,
                    outputDir: outputDir,
                    isCacheEnabled: false
                )
            case .prepareDependencies:
                try await compiler.build(
                    mode: .prepareDependencies,
                    buildOptions: buildOptions,
                    outputDir: outputDir,
                    isCacheEnabled: options.isCacheEnabled
                )
            }
        } catch {
            logger.error("Something went wrong during building")
            logger.error("Please execute with --verbose option.")
            throw Error.compilerError(error)
        }
    }
}
