import Foundation
import ScipioStorage
import TSCBasic

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

    public init(mode: Mode, options: Options, fileSystem: (any FileSystem) = LocalFileSystem.default) {
        self.mode = mode
        self.options = options
        self.fileSystem = fileSystem
    }

    private func resolveURL(_ fileURL: URL) async throws -> AbsolutePath {
        if fileURL.path.hasPrefix("/") {
            return try AbsolutePath(validating: fileURL.path)
        } else if let currentDirectory = await fileSystem.currentWorkingDirectory {
            let scipioCurrentDirectory = currentDirectory.absolutePath
            return try AbsolutePath(scipioCurrentDirectory, validating: fileURL.path)
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
        let packagePath = try await resolveURL(packageDirectory)
        let descriptionPackage: DescriptionPackage

        logger.info("🔁 Resolving Dependencies...")
        do {
            descriptionPackage = try await DescriptionPackage(
                packageDirectory: packagePath,
                mode: mode,
                onlyUseVersionsFromResolvedFile: options.shouldOnlyUseVersionsFromResolvedFile
            )
        } catch {
            throw Error.invalidPackage(packageDirectory)
        }

        let buildOptions = try await options.buildOptionsContainer.makeBuildOptions(descriptionPackage: descriptionPackage)
        guard !buildOptions.sdks.isEmpty else {
            throw Error.platformNotSpecified
        }

        try await fileSystem.createDirectory(descriptionPackage.workspaceDirectory.asURL, recursive: true)

        let outputDir = frameworkOutputDir.resolve(packageDirectory: packageDirectory)

        try await fileSystem.createDirectory(outputDir, recursive: true)

        let buildOptionsMatrix = try await options.buildOptionsContainer.makeBuildOptionsMatrix(descriptionPackage: descriptionPackage)

        let producer = FrameworkProducer(
            descriptionPackage: descriptionPackage,
            buildOptions: buildOptions,
            buildOptionsMatrix: buildOptionsMatrix,
            cachePolicies: options.cachePolicies,
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
            /// For clang target, whether to keep subdirectories in publicHeadersPath or not when copying public headers to Headers directory.
            /// If this is false, public headers are copied to Headers directory flattened (default).
            public var keepPublicHeadersStructure: Bool
            /// An option indicates use custom modulemaps for distributionb
            public var frameworkModuleMapGenerationPolicy: FrameworkModuleMapGenerationPolicy
            /// Whether to strip DWARF symbols or not
            public var stripStaticDWARFSymbols: Bool

            public init(
                buildConfiguration: BuildConfiguration = .release,
                platforms: PlatformSpecifier = .manifest,
                isSimulatorSupported: Bool = false,
                isDebugSymbolsEmbedded: Bool = false,
                frameworkType: FrameworkType = .dynamic,
                extraFlags: ExtraFlags? = nil,
                extraBuildParameters: [String: String]? = nil,
                enableLibraryEvolution: Bool = false,
                keepPublicHeadersStructure: Bool = false,
                frameworkModuleMapGenerationPolicy: FrameworkModuleMapGenerationPolicy = .autoGenerated,
                stripStaticDWARFSymbols: Bool = false
            ) {
                self.buildConfiguration = buildConfiguration
                self.platforms = platforms
                self.isSimulatorSupported = isSimulatorSupported
                self.isDebugSymbolsEmbedded = isDebugSymbolsEmbedded
                self.frameworkType = frameworkType
                self.extraFlags = extraFlags
                self.extraBuildParameters = extraBuildParameters
                self.enableLibraryEvolution = enableLibraryEvolution
                self.keepPublicHeadersStructure = keepPublicHeadersStructure
                self.frameworkModuleMapGenerationPolicy = frameworkModuleMapGenerationPolicy
                self.stripStaticDWARFSymbols = stripStaticDWARFSymbols
            }
        }
        public struct TargetBuildOptions: Sendable {
            public var buildConfiguration: BuildConfiguration?
            public var platforms: PlatformSpecifier?
            public var isSimulatorSupported: Bool?
            public var isDebugSymbolsEmbedded: Bool?
            public var frameworkType: FrameworkType?
            public var extraFlags: ExtraFlags?
            public var extraBuildParameters: [String: String]?
            public var enableLibraryEvolution: Bool?
            /// For clang target, whether to keep subdirectories in publicHeadersPath or not when copying public headers to Headers directory.
            /// If this is false or nil, public headers are copied to Headers directory flattened (default).
            public var keepPublicHeadersStructure: Bool?
            public var frameworkModuleMapGenerationPolicy: FrameworkModuleMapGenerationPolicy?
            /// Whether to strip DWARF symbols or not
            public var stripStaticDWARFSymbols: Bool?

            public init(
                buildConfiguration: BuildConfiguration? = nil,
                platforms: PlatformSpecifier? = nil,
                isSimulatorSupported: Bool? = nil,
                isDebugSymbolsEmbedded: Bool? = nil,
                frameworkType: FrameworkType? = nil,
                extraFlags: ExtraFlags? = nil,
                extraBuildParameters: [String: String]? = nil,
                enableLibraryEvolution: Bool? = nil,
                keepPublicHeadersStructure: Bool? = nil,
                frameworkModuleMapGenerationPolicy: FrameworkModuleMapGenerationPolicy? = nil,
                stripStaticDWARFSymbols: Bool? = nil
            ) {
                self.buildConfiguration = buildConfiguration
                self.platforms = platforms
                self.isSimulatorSupported = isSimulatorSupported
                self.isDebugSymbolsEmbedded = isDebugSymbolsEmbedded
                self.frameworkType = frameworkType
                self.extraBuildParameters = extraBuildParameters
                self.extraFlags = extraFlags
                self.enableLibraryEvolution = enableLibraryEvolution
                self.keepPublicHeadersStructure = keepPublicHeadersStructure
                self.frameworkModuleMapGenerationPolicy = frameworkModuleMapGenerationPolicy
                self.stripStaticDWARFSymbols = stripStaticDWARFSymbols
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

        public struct CachePolicy: Sendable {
            public enum CacheActorKind: Sendable {
                // Save built product to cacheStorage
                case producer
                // Consume stored caches
                case consumer
            }

            public let storage: any CacheStorage
            public let actors: Set<CacheActorKind>

            public init(storage: some CacheStorage, actors: Set<CacheActorKind>) {
                self.storage = storage
                self.actors = actors
            }

            private init(_ storage: LocalDiskCacheStorage) {
                self.init(storage: storage, actors: [.producer, .consumer])
            }

            /// The cache policy which treats built frameworks under the project's output directory (e.g. `XCFrameworks`)
            /// as valid caches, but does not saving to / restoring from any external locations.
            public static let project: Self = Self(
                storage: ProjectCacheStorage(),
                actors: [.producer]
            )

            /// The cache policy for saving to and restoring from the system cache directory `~/Library/Caches/Scipio`.
            public static let localDisk: Self = Self(LocalDiskCacheStorage(baseURL: nil))

            /// The cache policy for saving to and restoring from the custom cache directory `baseURL.appendingPath("Scipio")`.
            public static func localDisk(baseURL: URL) -> Self {
                Self(LocalDiskCacheStorage(baseURL: baseURL))
            }
        }

        public enum PlatformSpecifier: Sendable, Equatable {
            case manifest
            case specific(Set<Platform>)
        }

        public enum Platform: String, Hashable, Sendable {
            case iOS
            case macOS
            case macCatalyst
            case tvOS
            case watchOS
            case visionOS
        }

        public var buildOptionsContainer: BuildOptionsContainer
        public var shouldOnlyUseVersionsFromResolvedFile: Bool
        public var cachePolicies: [CachePolicy]
        public var overwrite: Bool
        public var verbose: Bool

        public init(
            baseBuildOptions: BuildOptions = .init(),
            buildOptionsMatrix: [String: TargetBuildOptions] = [:],
            shouldOnlyUseVersionsFromResolvedFile: Bool = false,
            cachePolicies: [CachePolicy] = [.project],
            overwrite: Bool = false,
            verbose: Bool = false
        ) {
            self.buildOptionsContainer = BuildOptionsContainer(
                baseBuildOptions: baseBuildOptions,
                buildOptionsMatrix: buildOptionsMatrix
            )
            self.shouldOnlyUseVersionsFromResolvedFile = shouldOnlyUseVersionsFromResolvedFile
            self.cachePolicies = cachePolicies
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
        case .visionOS:
            return isSimulatorSupported ? [.visionOS, .visionOSSimulator] : [.visionOS]
        }
    }
}

extension Runner.Options.BuildOptions {
    fileprivate func makeBuildOptions(
        descriptionPackage: DescriptionPackage,
        fileSystem: any FileSystem = LocalFileSystem.default
    ) async throws -> BuildOptions {
        let sdks = detectSDKsToBuild(
            platforms: platforms,
            package: descriptionPackage,
            isSimulatorSupported: isSimulatorSupported
        )
        let customFrameworkModuleMapContents: Data? = switch frameworkModuleMapGenerationPolicy {
        case .autoGenerated:
            nil
        case .custom(let url):
            try await fileSystem.readFileContents(url)
        }

        return BuildOptions(
            buildConfiguration: buildConfiguration,
            isDebugSymbolsEmbedded: isDebugSymbolsEmbedded,
            frameworkType: frameworkType,
            sdks: Set(sdks),
            extraFlags: extraFlags,
            extraBuildParameters: extraBuildParameters,
            enableLibraryEvolution: enableLibraryEvolution,
            keepPublicHeadersStructure: keepPublicHeadersStructure,
            customFrameworkModuleMapContents: customFrameworkModuleMapContents,
            stripStaticDWARFSymbols: stripStaticDWARFSymbols
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
            keepPublicHeadersStructure: fetch(
                \.keepPublicHeadersStructure,
                 by: \.keepPublicHeadersStructure
            ),
            frameworkModuleMapGenerationPolicy: fetch(
                \.frameworkModuleMapGenerationPolicy,
                 by: \.frameworkModuleMapGenerationPolicy
            ),
            stripStaticDWARFSymbols: fetch(\.stripStaticDWARFSymbols, by: \.stripStaticDWARFSymbols)
        )
    }
}

extension Runner.Options.BuildOptionsContainer {
    fileprivate func makeBuildOptions(descriptionPackage: DescriptionPackage) async throws -> BuildOptions {
        try await baseBuildOptions.makeBuildOptions(descriptionPackage: descriptionPackage)
    }

    fileprivate func makeBuildOptionsMatrix(descriptionPackage: DescriptionPackage) async throws -> [String: BuildOptions] {
        try await buildOptionsMatrix.asyncReduce(into: [String: BuildOptions]()) { partialResult, buildOption in
            let newBuildOptions = try await baseBuildOptions.overridden(by: buildOption.value)
                .makeBuildOptions(descriptionPackage: descriptionPackage)
            partialResult.updateValue(newBuildOptions, forKey: buildOption.key)
        }
    }
}

extension [Runner.Options.CachePolicy] {
    public static let disabled: Self = []
}
