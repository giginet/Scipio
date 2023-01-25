import Foundation
import OrderedCollections
import protocol TSCBasic.FileSystem
import var TSCBasic.localFileSystem

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
        public struct BuildOptions {
            public var buildConfiguration: BuildConfiguration
            public var platforms: PlatformSpecifier
            public var isSimulatorSupported: Bool
            public var isDebugSymbolsEmbedded: Bool
            public var frameworkType: FrameworkType

            public init(
                buildConfiguration: BuildConfiguration = .release,
                platforms: PlatformSpecifier = .manifest,
                isSimulatorSupported: Bool = false,
                isDebugSymbolsEmbedded: Bool = false,
                frameworkType: FrameworkType = .dynamic
            ) {
                self.buildConfiguration = buildConfiguration
                self.platforms = platforms
                self.isSimulatorSupported = isSimulatorSupported
                self.isDebugSymbolsEmbedded = isDebugSymbolsEmbedded
                self.frameworkType = frameworkType
            }
        }
        public enum CacheMode {
            case disabled
            case project
            case storage(any CacheStorage)
        }
        public enum PlatformSpecifier: Equatable {
            case manifest
            case specific(Set<Platform>)
        }

        public enum Platform: String, Hashable {
            case iOS
            case macOS
            case macCatalyst
            case tvOS
            case watchOS
        }

        public var baseBuildOptions: BuildOptions
        public var buildOptionMatrix: [String: BuildOptions]
        public var outputDirectory: URL?
        public var cacheMode: CacheMode
        public var skipProjectGeneration: Bool
        public var overwrite: Bool
        public var verbose: Bool

        public init(
            baseBuildOptions: BuildOptions = .init(),
            buildOptionsMatrix: [String: BuildOptions] = [:],
            outputDirectory: URL? = nil,
            cacheMode: CacheMode = .project,
            skipProjectGeneration: Bool = false,
            overwrite: Bool = false,
            verbose: Bool = false
        ) {
            self.baseBuildOptions = baseBuildOptions
            self.buildOptionMatrix = buildOptionsMatrix
            self.outputDirectory = outputDirectory
            self.cacheMode = cacheMode
            self.skipProjectGeneration = skipProjectGeneration
            self.overwrite = overwrite
            self.verbose = verbose
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
            return URL(fileURLWithPath: fileURL.path, relativeTo: currentDirectory.asURL)
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

        let buildOptions = buildOptions(from: options.baseBuildOptions, package: package)
        guard !buildOptions.sdks.isEmpty else {
            throw Error.platformNotSpecified
        }

        try fileSystem.createDirectory(package.workspaceDirectory.absolutePath, recursive: true)

        let resolver = Resolver(package: package)
        try await resolver.resolve()

        if options.skipProjectGeneration {
            logger.info("Skip Xcode project generation")
        } else {
            let generator = ProjectGenerator(package: package,
                                             buildOptions: buildOptions)
            do {
                try generator.generate()
            } catch let error as LocalizedError {
                logger.error("""
                Project generation is failed:
                \(error.errorDescription ?? "Unknown reason")
            """)
                throw error
            }
        }

        let outputDir = frameworkOutputDir.resolve(packageDirectory: packageDirectory)

        try fileSystem.createDirectory(outputDir.absolutePath, recursive: true)

        let buildOptionsMatrix = options.buildOptionMatrix.mapValues { runnerOptions in
            self.buildOptions(
                from: options.baseBuildOptions.merge(overriding: runnerOptions),
                package: package
            )
        }

        let producer = FrameworkProducer(
            mode: mode,
            rootPackage: package,
            buildOptions: buildOptions,
            buildOptionsMatrix: buildOptionsMatrix,
            cacheMode: options.cacheMode,
            overwrite: options.overwrite,
            outputDir: outputDir
        )
        do {
            try await producer.produce()
            logger.info("❇️ Succeeded.", metadata: .color(.green))
        } catch {
            logger.error("Something went wrong during building", metadata: .color(.red))
            if !options.verbose {
                logger.error("Please execute with --verbose option.", metadata: .color(.red))
            }
            logger.error("\(error.localizedDescription)")
            throw Error.compilerError(error)
        }
    }

    private func buildOptions(
        from runnerOption: Runner.Options.BuildOptions,
        package: Package
    ) -> BuildOptions {
        let sdks = detectSDKsToBuild(platforms: runnerOption.platforms, package: package, isSimulatorSupported: runnerOption.isSimulatorSupported)
        return BuildOptions(
            buildConfiguration: runnerOption.buildConfiguration,
            isDebugSymbolsEmbedded: runnerOption.isDebugSymbolsEmbedded,
            frameworkType: runnerOption.frameworkType,
            sdks: OrderedSet(sdks)
        )
    }

    private func detectSDKsToBuild(
        platforms: Runner.Options.PlatformSpecifier,
        package: Package,
        isSimulatorSupported: Bool
    ) -> Set<SDK> {
        switch platforms {
        case .manifest:
            return Set(package.supportedSDKs.reduce([]) { sdks, sdk in
                sdks + (isSimulatorSupported ? sdk.extractForSimulators() : [sdk])
            })
        case .specific(let platforms):
            return Set(platforms.reduce([]) { sdks, sdk in
                sdks + sdk.extractSDK(isSimulatorSupported: isSimulatorSupported)
            })
        }
    }
}

extension Runner.Options.BuildOptions {
    fileprivate func merge(overriding overridingOptions: Self) -> Self {
        let defaultOptions: Self = .init()

        func fetch<T: Equatable>(_ key: KeyPath<Self, T>) -> T {
            let baseValue = self[keyPath: key]
            let newValue = overridingOptions[keyPath: key]
            let defaultValue = defaultOptions[keyPath: key]
            if baseValue != newValue && newValue == defaultValue {
                return defaultValue
            }
            return newValue
        }

        return .init(
            buildConfiguration: fetch(\.buildConfiguration),
            platforms: fetch(\.platforms),
            isSimulatorSupported: fetch(\.isSimulatorSupported),
            isDebugSymbolsEmbedded: fetch(\.isDebugSymbolsEmbedded),
            frameworkType: fetch(\.frameworkType)
        )

    }
}

extension Runner.Options.Platform {
    fileprivate func extractSDK(isSimulatorSupported: Bool) -> Set<SDK> {
        if isSimulatorSupported {
            switch self {
            case .macOS: return [.macOS]
            case .macCatalyst: return [.macCatalyst]
            case .iOS: return [.iOS, .iOSSimulator]
            case .tvOS: return [.tvOS, .tvOSSimulator]
            case .watchOS: return [.watchOS, .watchOSSimulator]
            }
        } else {
            switch self {
            case .macOS: return [.macOS]
            case .macCatalyst: return [.macCatalyst]
            case .iOS: return [.iOS]
            case .tvOS: return [.tvOS]
            case .watchOS: return [.watchOS]
            }
        }
    }
}
