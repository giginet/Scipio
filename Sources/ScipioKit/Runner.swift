import Foundation
import OrderedCollections
import struct TSCBasic.AbsolutePath
import protocol TSCBasic.FileSystem
import var TSCBasic.localFileSystem

public typealias PlatformMatrix = [String: OrderedSet<SDK>]

public struct Runner {
    private let options: Options
    private let fileSystem: any FileSystem

    public enum Mode {
        case createPackage
        case prepareDependencies
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

    private func resolveURL(_ fileURL: URL) throws -> AbsolutePath {
        if fileURL.path.hasPrefix("/") {
            return try AbsolutePath(validating: fileURL.path)
        } else if let currentDirectory = fileSystem.currentWorkingDirectory {
            return AbsolutePath(currentDirectory, fileURL.path)
        } else {
            return try! AbsolutePath(validating: fileURL.path)
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
        let packagePath = try resolveURL(packageDirectory)
        let descriptionPackage: DescriptionPackage
        do {
            descriptionPackage = try DescriptionPackage(packageDirectory: packagePath, mode: mode)
        } catch {
            throw Error.invalidPackage(packageDirectory)
        }

        let buildOptions = options.buildOptionsContainer.makeBuildOptions(descriptionPackage: descriptionPackage)
        guard !buildOptions.sdks.isEmpty else {
            throw Error.platformNotSpecified
        }

        try fileSystem.createDirectory(descriptionPackage.workspaceDirectory, recursive: true)

        let resolver = Resolver(package: descriptionPackage)
        try await resolver.resolve()

        let outputDir = frameworkOutputDir.resolve(packageDirectory: packageDirectory)

        try fileSystem.createDirectory(outputDir.absolutePath, recursive: true)

        let buildOptionsMatrix = options.buildOptionsContainer.makeBuildOptionsMatrix(descriptionPackage: descriptionPackage)

        let producer = FrameworkProducer(
            descriptionPackage: descriptionPackage,
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
}

extension Runner {
    public struct Options {
        public struct BuildOptions {
            public var buildConfiguration: BuildConfiguration
            public var platforms: PlatformSpecifier
            public var isSimulatorSupported: Bool
            public var isDebugSymbolsEmbedded: Bool
            public var frameworkType: FrameworkType
            public var extraFlags: ExtraFlags?
            public var extraBuildParameters: [String: String]?
            public var enableLibraryEvolution: Bool

            public init(
                buildConfiguration: BuildConfiguration = .release,
                platforms: PlatformSpecifier = .manifest,
                isSimulatorSupported: Bool = false,
                isDebugSymbolsEmbedded: Bool = false,
                frameworkType: FrameworkType = .dynamic,
                extraFlags: ExtraFlags? = nil,
                extraBuildParameters: [String: String]? = nil,
                enableLibraryEvolution: Bool = true
            ) {
                self.buildConfiguration = buildConfiguration
                self.platforms = platforms
                self.isSimulatorSupported = isSimulatorSupported
                self.isDebugSymbolsEmbedded = isDebugSymbolsEmbedded
                self.frameworkType = frameworkType
                self.extraFlags = extraFlags
                self.extraBuildParameters = extraBuildParameters
                self.enableLibraryEvolution = enableLibraryEvolution
            }
        }
        public struct TargetBuildOptions {
            public var buildConfiguration: BuildConfiguration?
            public var platforms: PlatformSpecifier?
            public var isSimulatorSupported: Bool?
            public var isDebugSymbolsEmbedded: Bool?
            public var frameworkType: FrameworkType?
            public var extraFlags: ExtraFlags?
            public var extraBuildParameters: [String: String]?
            public var enableLibraryEvolution: Bool?

            public init(
                buildConfiguration: BuildConfiguration? = nil,
                platforms: PlatformSpecifier? = nil,
                isSimulatorSupported: Bool? = nil,
                isDebugSymbolsEmbedded: Bool? = nil,
                frameworkType: FrameworkType? = nil,
                extraFlags: ExtraFlags? = nil,
                extraBuildParameters: [String: String]? = nil,
                enableLibraryEvolution: Bool? = false
            ) {
                self.buildConfiguration = buildConfiguration
                self.platforms = platforms
                self.isSimulatorSupported = isSimulatorSupported
                self.isDebugSymbolsEmbedded = isDebugSymbolsEmbedded
                self.frameworkType = frameworkType
                self.extraFlags = extraFlags
                self.enableLibraryEvolution = enableLibraryEvolution
            }
        }

        public struct BuildOptionsContainer {
            public init(
                baseBuildOptions: BuildOptions = .init(),
                buildOptionsMatrix: [String: Runner.Options.TargetBuildOptions] = [:]
            ) {
                self.baseBuildOptions = baseBuildOptions
                self.buildOptionsMatrix = buildOptionsMatrix
            }

            public var baseBuildOptions: BuildOptions
            public var buildOptionsMatrix: [String: TargetBuildOptions]
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

        public var buildOptionsContainer: BuildOptionsContainer
        public var cacheMode: CacheMode
        public var overwrite: Bool
        public var verbose: Bool

        public init(
            baseBuildOptions: BuildOptions = .init(),
            buildOptionsMatrix: [String: TargetBuildOptions] = [:],
            cacheMode: CacheMode = .project,
            overwrite: Bool = false,
            verbose: Bool = false
        ) {
            self.buildOptionsContainer = BuildOptionsContainer(
                baseBuildOptions: baseBuildOptions,
                buildOptionsMatrix: buildOptionsMatrix
            )
            self.cacheMode = cacheMode
            self.overwrite = overwrite
            self.verbose = verbose
        }
    }
}

extension Runner.Options.Platform {
    fileprivate func extractSDK(isSimulatorSupported: Bool) -> Set<SDK> {
        switch self {
        case .macOS:
            return [.macOS]
        case .macCatalyst:
            return [.macCatalyst]
        case .iOS:
            return isSimulatorSupported ? [.iOS, .iOSSimulator] : [.iOS]
        case .tvOS:
            return isSimulatorSupported ? [.tvOS, .tvOSSimulator] : [.tvOS]
        case .watchOS:
            return isSimulatorSupported ? [.watchOS, .watchOSSimulator] : [.watchOS]
        }
    }
}

extension Runner.Options.BuildOptions {
    fileprivate func makeBuildOptions(descriptionPackage: DescriptionPackage) -> BuildOptions {
        let sdks = detectSDKsToBuild(
            platforms: platforms,
            package: descriptionPackage,
            isSimulatorSupported: isSimulatorSupported
        )
        return BuildOptions(
            buildConfiguration: buildConfiguration,
            isDebugSymbolsEmbedded: isDebugSymbolsEmbedded,
            frameworkType: frameworkType,
            sdks: OrderedSet(sdks),
            extraFlags: extraFlags,
            extraBuildParameters: extraBuildParameters,
            enableLibraryEvolution: enableLibraryEvolution
        )
    }

    private func detectSDKsToBuild(
        platforms: Runner.Options.PlatformSpecifier,
        package: DescriptionPackage,
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

    fileprivate func overridden(by overridingOptions: Runner.Options.TargetBuildOptions) -> Self {
        func fetch<T>(_ baseKeyPath: KeyPath<Self, T>, by overridingKeyPath: KeyPath<Runner.Options.TargetBuildOptions, T?>) -> T {
            overridingOptions[keyPath: overridingKeyPath] ?? self[keyPath: baseKeyPath]
        }

        let mergedExtraBuildParameters = extraBuildParameters?
            .merging(
                overridingOptions.extraBuildParameters ?? [:],
                uniquingKeysWith: { $1 }
            ) ?? overridingOptions.extraBuildParameters

        let mergedExtraFlags = extraFlags?
            .concatenating(overridingOptions.extraFlags) ?? overridingOptions.extraFlags

        return .init(
            buildConfiguration: fetch(\.buildConfiguration, by: \.buildConfiguration),
            platforms: fetch(\.platforms, by: \.platforms),
            isSimulatorSupported: fetch(\.isSimulatorSupported, by: \.isSimulatorSupported),
            isDebugSymbolsEmbedded: fetch(\.isDebugSymbolsEmbedded, by: \.isDebugSymbolsEmbedded),
            frameworkType: fetch(\.frameworkType, by: \.frameworkType),
            extraFlags: mergedExtraFlags,
            extraBuildParameters: mergedExtraBuildParameters,
            enableLibraryEvolution: fetch(\.enableLibraryEvolution, by: \.enableLibraryEvolution)
        )
    }
}

extension Runner.Options.BuildOptionsContainer {
    fileprivate func makeBuildOptions(descriptionPackage: DescriptionPackage) -> BuildOptions {
        baseBuildOptions.makeBuildOptions(descriptionPackage: descriptionPackage)
    }

    fileprivate func makeBuildOptionsMatrix(descriptionPackage: DescriptionPackage) -> [String: BuildOptions] {
        buildOptionsMatrix.mapValues { runnerOptions in
            baseBuildOptions.overridden(by: runnerOptions)
                .makeBuildOptions(descriptionPackage: descriptionPackage)
        }
    }
}
