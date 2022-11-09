import Foundation

public struct Runner {
    private let options: Options
    private let fileSystem: any FileSystem

    public enum Mode {
        case createPackage
        case prepareDependencies
    }

    public enum CacheStorageKind {
        case local
        case custom(any CacheStorage)
    }

    public enum Error: Swift.Error, LocalizedError {
        case invalidPackage(URL)
        case platformNotSpecified
        case compilerError(Swift.Error)

        public var errorDescription: String? {
            switch self {
            case .platformNotSpecified:
                return "Any platforms are not spcified in Package.swift"
            case .invalidPackage(let path):
                return "Invalid package. \(path.path)"
            case .compilerError(let error):
                return "\(error.localizedDescription)"
            }
        }
    }

    public struct Options {
        public init(
            buildConfiguration: BuildConfiguration,
            isSimulatorSupported: Bool,
            isDebugSymbolsEmbedded: Bool,
            frameworkType: FrameworkType,
            outputDirectory: URL? = nil,
            cacheMode: CacheMode,
            verbose: Bool
        ) {
            self.buildConfiguration = buildConfiguration
            self.isSimulatorSupported = isSimulatorSupported
            self.isDebugSymbolsEmbedded = isDebugSymbolsEmbedded
            self.frameworkType = frameworkType
            self.outputDirectory = outputDirectory
            self.cacheMode = cacheMode
            self.verbose = verbose
        }

        public var buildConfiguration: BuildConfiguration
        public var isSimulatorSupported: Bool
        public var isDebugSymbolsEmbedded: Bool
        public var frameworkType: FrameworkType
        public var outputDirectory: URL?
        public var cacheMode: CacheMode
        public var verbose: Bool

        public enum CacheMode {
            case disabled
            case project
            case storage(any CacheStorage)

            func extract() -> (Bool, CacheStorage?) {
                switch self {
                case .disabled:
                    return (false, nil)
                case .project:
                    return (true, nil)
                case .storage(let cacheStorage):
                    return (true, cacheStorage)
                }
            }
        }
    }
    private var mode: Mode

    public init(mode: Mode, options: Options, fileSystem: (any FileSystem) = localFileSystem) {
        self.mode = mode
        if options.verbose {
            setLogLevel(.trace)
        } else {
            setLogLevel(.info)
        }

        self.options = options
        self.fileSystem = fileSystem
    }

    private func resolveURL(_ fileURL: URL) -> URL {
        if fileURL.path.hasPrefix("/") {
            return fileURL
        } else if let currentDirectory = fileSystem.currentWorkingDirectory {
            return URL(fileURLWithPath: fileURL.path, relativeTo: currentDirectory)
        } else {
            return fileURL
        }
    }

    public enum OutputDirectory {
        case `default`
        case custom(URL)

        fileprivate func resolve(packageDirectory: URL) -> URL {
            switch self {
            case .default:
                return packageDirectory.appendingPathComponent("XCFrameworks")
            case .custom(let url):
                return url
            }
        }
    }

    public func run(packageDirectory: URL, frameworkOutputDir: OutputDirectory) async throws {
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
                                        frameworkType: options.frameworkType,
                                        sdks: sdks)
        try fileSystem.createDirectory(package.workspaceDirectory, recursive: true)

        let resolver = Resolver(package: package)
        try await resolver.resolve()

        let generator = ProjectGenerator(package: package)
        try generator.generate(embedDebugSymbols: buildOptions.isDebugSymbolsEmbedded,
                               frameworkType: buildOptions.frameworkType)

        let outputDir = frameworkOutputDir.resolve(packageDirectory: packageDirectory)

        try fileSystem.createDirectory(outputDir, recursive: true)

        let (isCacheEnabled, cacheStorage) = options.cacheMode.extract()
        let compiler = Compiler(rootPackage: package,
                                cacheStorage: cacheStorage,
                                executor: ProcessExecutor(),
                                fileSystem: fileSystem)
        do {
            switch mode {
            case .createPackage:
                try await compiler.build(
                    mode: .createPackage,
                    buildOptions: buildOptions,
                    outputDir: outputDir,
                    isCacheEnabled: isCacheEnabled
                )
            case .prepareDependencies:
                try await compiler.build(
                    mode: .prepareDependencies,
                    buildOptions: buildOptions,
                    outputDir: outputDir,
                    isCacheEnabled: isCacheEnabled
                )
            }
            logger.info("❇️ Succeeded.", metadata: .color(.green))
        } catch {
            logger.error("Something went wrong during building", metadata: .color(.red))
            logger.error("Please execute with --verbose option.", metadata: .color(.red))
            logger.error("\(error.localizedDescription)")
            throw Error.compilerError(error)
        }
    }
}
