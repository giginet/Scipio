import Foundation
import ScipioStorage
import struct TSCBasic.AbsolutePath
import protocol TSCBasic.FileSystem
import var TSCBasic.localFileSystem

public typealias PlatformMatrix = [String: Set<SDK>]

public struct Runner {
    private let options: Options
    private let fileSystem: any FileSystem

    public enum Mode: Sendable {
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
        self.options = options
        self.fileSystem = fileSystem
    }

    private func resolveURL(_ fileURL: URL) throws -> ScipioAbsolutePath {
        if fileURL.path.hasPrefix("/") {
            return try AbsolutePath(validating: fileURL.path)
        } else if let currentDirectory = fileSystem.currentWorkingDirectory {
            #if swift(>=5.10)
            let scipioCurrentDirectory = try ScipioAbsolutePath(validating: currentDirectory.pathString)
            return try ScipioAbsolutePath(scipioCurrentDirectory, validating: fileURL.path)
            #else
            return ScipioAbsolutePath(currentDirectory, fileURL.path)
            #endif
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

        logger.info("🔁 Resolving Dependencies...")
        do {
            descriptionPackage = try DescriptionPackage(
                packageDirectory: packagePath,
                mode: mode,
                onlyUseVersionsFromResolvedFile: false,
                toolchainEnvironment: options.toolchainEnvironment
            )
        } catch {
            throw Error.invalidPackage(packageDirectory)
        }

        let buildOptions = try options.buildOptionsContainer.makeBuildOptions(descriptionPackage: descriptionPackage)
        guard !buildOptions.sdks.isEmpty else {
            throw Error.platformNotSpecified
        }

        try fileSystem.createDirectory(descriptionPackage.workspaceDirectory, recursive: true)

        let outputDir = frameworkOutputDir.resolve(packageDirectory: packageDirectory)

        try fileSystem.createDirectory(outputDir.absolutePath, recursive: true)

        let buildOptionsMatrix = try options.buildOptionsContainer.makeBuildOptionsMatrix(descriptionPackage: descriptionPackage)

        let producer = FrameworkProducer(
            descriptionPackage: descriptionPackage,
            buildOptions: buildOptions,
            buildOptionsMatrix: buildOptionsMatrix,
            cacheMode: options.cacheMode,
            overwrite: options.overwrite,
            outputDir: outputDir,
            toolchainEnvironment: options.toolchainEnvironment
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
            /// An option indicates use custom modulemaps for distributionb
            public var frameworkModuleMapGenerationPolicy: FrameworkModuleMapGenerationPolicy

            public init(
                buildConfiguration: BuildConfiguration = .release,
                platforms: PlatformSpecifier = .manifest,
                isSimulatorSupported: Bool = false,
                isDebugSymbolsEmbedded: Bool = false,
                frameworkType: FrameworkType = .dynamic,
                extraFlags: ExtraFlags? = nil,
                extraBuildParameters: [String: String]? = nil,
                enableLibraryEvolution: Bool = false,
                frameworkModuleMapGenerationPolicy: FrameworkModuleMapGenerationPolicy = .autoGenerated
            ) {
                self.buildConfiguration = buildConfiguration
                self.platforms = platforms
                self.isSimulatorSupported = isSimulatorSupported
                self.isDebugSymbolsEmbedded = isDebugSymbolsEmbedded
                self.frameworkType = frameworkType
                self.extraFlags = extraFlags
                self.extraBuildParameters = extraBuildParameters
                self.enableLibraryEvolution = enableLibraryEvolution
                self.frameworkModuleMapGenerationPolicy = frameworkModuleMapGenerationPolicy
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
            public var frameworkModuleMapGenerationPolicy: FrameworkModuleMapGenerationPolicy?

            public init(
                buildConfiguration: BuildConfiguration? = nil,
                platforms: PlatformSpecifier? = nil,
                isSimulatorSupported: Bool? = nil,
                isDebugSymbolsEmbedded: Bool? = nil,
                frameworkType: FrameworkType? = nil,
                extraFlags: ExtraFlags? = nil,
                extraBuildParameters: [String: String]? = nil,
                enableLibraryEvolution: Bool? = nil,
                frameworkModuleMapGenerationPolicy: FrameworkModuleMapGenerationPolicy? = nil
            ) {
                self.buildConfiguration = buildConfiguration
                self.platforms = platforms
                self.isSimulatorSupported = isSimulatorSupported
                self.isDebugSymbolsEmbedded = isDebugSymbolsEmbedded
                self.frameworkType = frameworkType
                self.extraBuildParameters = extraBuildParameters
                self.extraFlags = extraFlags
                self.enableLibraryEvolution = enableLibraryEvolution
                self.frameworkModuleMapGenerationPolicy = frameworkModuleMapGenerationPolicy
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

        public enum CacheMode: Sendable {
            public enum CacheActorKind: Sendable {
                // Save built product to cacheStorage
                case producer
                // Consume stored caches
                case consumer
            }

            case disabled
            case project
            case storage(any CacheStorage, Set<CacheActorKind>)
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
            case visionOS
        }

        public var buildOptionsContainer: BuildOptionsContainer
        public var shouldOnlyUseVersionsFromResolvedFile: Bool
        public var cacheMode: CacheMode
        public var overwrite: Bool
        public var verbose: Bool
        public var toolchainEnvironment: ToolchainEnvironment?

        public init(
            baseBuildOptions: BuildOptions = .init(),
            buildOptionsMatrix: [String: TargetBuildOptions] = [:],
            shouldOnlyUseVersionsFromResolvedFile: Bool = false,
            cacheMode: CacheMode = .project,
            overwrite: Bool = false,
            verbose: Bool = false,
            toolchainEnvironment: ToolchainEnvironment? = nil
        ) {
            self.buildOptionsContainer = BuildOptionsContainer(
                baseBuildOptions: baseBuildOptions,
                buildOptionsMatrix: buildOptionsMatrix
            )
            self.shouldOnlyUseVersionsFromResolvedFile = shouldOnlyUseVersionsFromResolvedFile
            self.cacheMode = cacheMode
            self.overwrite = overwrite
            self.verbose = verbose
            self.toolchainEnvironment = toolchainEnvironment
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
        case .visionOS:
            return isSimulatorSupported ? [.visionOS, .visionOSSimulator] : [.visionOS]
        }
    }
}

extension Runner.Options.BuildOptions {
    fileprivate func makeBuildOptions(descriptionPackage: DescriptionPackage, fileSystem: any FileSystem = localFileSystem) throws -> BuildOptions {
        let sdks = detectSDKsToBuild(
            platforms: platforms,
            package: descriptionPackage,
            isSimulatorSupported: isSimulatorSupported
        )
        let customFrameworkModuleMapContents: Data? = switch frameworkModuleMapGenerationPolicy {
        case .autoGenerated:
            nil
        case .custom(let url):
            try fileSystem.readFileContents(url.absolutePath.spmAbsolutePath)
        }

        return BuildOptions(
            buildConfiguration: buildConfiguration,
            isDebugSymbolsEmbedded: isDebugSymbolsEmbedded,
            frameworkType: frameworkType,
            sdks: Set(sdks),
            extraFlags: extraFlags,
            extraBuildParameters: extraBuildParameters,
            enableLibraryEvolution: enableLibraryEvolution,
            customFrameworkModuleMapContents: customFrameworkModuleMapContents
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
            enableLibraryEvolution: fetch(\.enableLibraryEvolution, by: \.enableLibraryEvolution),
            frameworkModuleMapGenerationPolicy: fetch(\.frameworkModuleMapGenerationPolicy, by: \.frameworkModuleMapGenerationPolicy)
        )
    }
}

extension Runner.Options.BuildOptionsContainer {
    fileprivate func makeBuildOptions(descriptionPackage: DescriptionPackage) throws -> BuildOptions {
        try baseBuildOptions.makeBuildOptions(descriptionPackage: descriptionPackage)
    }

    fileprivate func makeBuildOptionsMatrix(descriptionPackage: DescriptionPackage) throws -> [String: BuildOptions] {
        try buildOptionsMatrix.mapValues { runnerOptions in
            try baseBuildOptions.overridden(by: runnerOptions)
                .makeBuildOptions(descriptionPackage: descriptionPackage)
        }
    }
}
