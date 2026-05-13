import Foundation
import CacheStorage
import Algorithms
import PackageManifestKit
import ScipioKitCore

private let jsonEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
}()

private let jsonDecoder = {
    let decoder = JSONDecoder()
    return decoder
}()

struct ClangChecker<E: Executor> {
    private let executor: E

    init(executor: E = ProcessExecutor()) {
        self.executor = executor
    }

    func fetchClangVersion() async throws -> String? {
        let result = try await executor.execute("/usr/bin/xcrun", "clang", "--version")
        let rawString = try result.unwrapOutput()
        return parseClangVersion(from: rawString)
    }

    private func parseClangVersion(from outputString: String) -> String? {
        let regex = /Apple clang version .+ \((?<version>.+)\)/
        guard let result = try? regex.firstMatch(in: outputString) else {
            return nil
        }
        return String(result.output.version)
    }
}

public struct DependencyCacheKeyChecksum: Codable, Hashable, Sendable {
    public var targetName: String
    public var checksum: String

    public init(targetName: String, checksum: String) {
        self.targetName = targetName
        self.checksum = checksum
    }
}

private func sortDependencyCacheKeyChecksums(
    _ checksums: [DependencyCacheKeyChecksum]
) -> [DependencyCacheKeyChecksum] {
    checksums.sorted {
        if $0.targetName == $1.targetName {
            return $0.checksum < $1.checksum
        }
        return $0.targetName < $1.targetName
    }
}

public struct SwiftPMCacheKey: CacheKey {
    /// The canonical repository URL the manifest was loaded from, for local packages only.
    public var localPackageCanonicalLocation: String?
    public var pin: Pin.State
    public var targetName: String
    var buildOptions: BuildOptions
    public var clangVersion: String
    public var xcodeVersion: XcodeVersion
    public var scipioVersion: String?
    public var dependencyCacheKeyChecksums: [DependencyCacheKeyChecksum]

    init(
        localPackageCanonicalLocation: String?,
        pin: Pin.State,
        targetName: String,
        buildOptions: BuildOptions,
        clangVersion: String,
        xcodeVersion: XcodeVersion,
        scipioVersion: String? = nil,
        dependencyCacheKeyChecksums: [DependencyCacheKeyChecksum] = []
    ) {
        self.localPackageCanonicalLocation = localPackageCanonicalLocation
        self.pin = pin
        self.targetName = targetName
        self.buildOptions = buildOptions
        self.clangVersion = clangVersion
        self.xcodeVersion = xcodeVersion
        self.scipioVersion = scipioVersion
        self.dependencyCacheKeyChecksums = sortDependencyCacheKeyChecksums(dependencyCacheKeyChecksums)
    }

    private enum CodingKeys: String, CodingKey {
        case localPackageCanonicalLocation
        case pin
        case targetName
        case buildOptions
        case clangVersion
        case xcodeVersion
        case scipioVersion
        case dependencyCacheKeyChecksums
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.localPackageCanonicalLocation = try container.decodeIfPresent(String.self, forKey: .localPackageCanonicalLocation)
        self.pin = try container.decode(Pin.State.self, forKey: .pin)
        self.targetName = try container.decode(String.self, forKey: .targetName)
        self.buildOptions = try container.decode(BuildOptions.self, forKey: .buildOptions)
        self.clangVersion = try container.decode(String.self, forKey: .clangVersion)
        self.xcodeVersion = try container.decode(XcodeVersion.self, forKey: .xcodeVersion)
        self.scipioVersion = try container.decodeIfPresent(String.self, forKey: .scipioVersion)
        self.dependencyCacheKeyChecksums = sortDependencyCacheKeyChecksums(try container
            .decodeIfPresent([DependencyCacheKeyChecksum].self, forKey: .dependencyCacheKeyChecksums)
            ?? [])
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(localPackageCanonicalLocation, forKey: .localPackageCanonicalLocation)
        try container.encode(pin, forKey: .pin)
        try container.encode(targetName, forKey: .targetName)
        try container.encode(buildOptions, forKey: .buildOptions)
        try container.encode(clangVersion, forKey: .clangVersion)
        try container.encode(xcodeVersion, forKey: .xcodeVersion)
        try container.encodeIfPresent(scipioVersion, forKey: .scipioVersion)
        try container.encode(sortDependencyCacheKeyChecksums(dependencyCacheKeyChecksums), forKey: .dependencyCacheKeyChecksums)
    }
}

struct CacheSystem: Sendable {
    static let defaultParallelNumber = 8
    private let outputDirectory: URL
    private let fileSystem: any FileSystem

    struct CacheTarget: Hashable, Sendable {
        var buildProduct: BuildProduct
        var buildOptions: BuildOptions
    }

    enum Error: LocalizedError {
        case revisionNotDetected(String)
        case compilerVersionNotDetected
        case xcodeVersionNotDetected
        case couldNotReadVersionFile(URL)

        var errorDescription: String? {
            switch self {
            case .revisionNotDetected(let packageName):
                return "Repository version is not detected for \(packageName)."
            case .compilerVersionNotDetected:
                return "Compiler version not detected. Please check your environment"
            case .xcodeVersionNotDetected:
                return "Xcode version not detected. Please check your environment"
            case .couldNotReadVersionFile(let path):
                return "Could not read VersionFile \(path.path)"
            }
        }
    }

    init(
        outputDirectory: URL,
        fileSystem: any FileSystem = LocalFileSystem.default
    ) {
        self.outputDirectory = outputDirectory
        self.fileSystem = fileSystem
    }

    func cacheFrameworks(
        _ targets: Set<CacheTarget>,
        cacheKeys: [CacheTarget: SwiftPMCacheKey],
        to storages: [any FrameworkCacheStorage]
    ) async {
        for storage in storages {
            await cacheFrameworks(targets, cacheKeys: cacheKeys, to: storage)
        }
    }

    private func cacheFrameworks(
        _ targets: Set<CacheTarget>,
        cacheKeys: [CacheTarget: SwiftPMCacheKey],
        to storage: some FrameworkCacheStorage
    ) async {
        let chunked = targets.chunks(ofCount: storage.parallelNumber ?? CacheSystem.defaultParallelNumber)

        let storageName = storage.displayName
        for chunk in chunked {
            await withTaskGroup(of: Void.self) { group in
                for target in chunk {
                    let frameworkName = target.buildProduct.frameworkName
                    group.addTask {
                        let frameworkPath = outputDirectory.appendingPathComponent(frameworkName)
                        do {
                            logger.info(
                                "🚀 Cache \(frameworkName) to cache storage: \(storageName)",
                                metadata: .color(.green)
                            )
                            guard let cacheKey = cacheKeys[target] else { return }
                            try await cacheFramework(at: frameworkPath, for: cacheKey, to: storage)
                        } catch {
                            logger.warning("⚠️ Can't create caches for \(frameworkPath.path)")
                        }
                    }
                }
                await group.waitForAll()
            }
        }
    }

    private func cacheFramework(at frameworkPath: URL, for cacheKey: SwiftPMCacheKey, to storage: any FrameworkCacheStorage) async throws {
        try await storage.cacheFramework(frameworkPath, for: cacheKey)
    }

    func generateVersionFile(for target: CacheTarget, cacheKey: SwiftPMCacheKey) async throws {
        let data = try jsonEncoder.encode(cacheKey)
        let versionFilePath = outputDirectory.appendingPathComponent(versionFileName(for: target.buildProduct.target.name))
        try fileSystem.writeFileContents(
            versionFilePath,
            data: data
        )
    }

    func generateVersionFile(for target: CacheTarget) async throws {
        let cacheKey = try await calculateCacheKey(of: target)
        try await generateVersionFile(for: target, cacheKey: cacheKey)
    }

    func existsValidCache(cacheKey: SwiftPMCacheKey) async -> Bool {
        do {
            let versionFilePath = versionFilePath(for: cacheKey.targetName)
            guard fileSystem.exists(versionFilePath) else { return false }
            let decoder = JSONDecoder()
            guard let contents = try? fileSystem.readFileContents(versionFilePath) else {
                throw Error.couldNotReadVersionFile(versionFilePath)
            }
            let versionFileKey = try decoder.decode(SwiftPMCacheKey.self, from: Data(contents))
            return versionFileKey == cacheKey
        } catch {
            return false
        }
    }

    enum RestoreResult {
        case succeeded
        case failed(LocalizedError?)
        case noCache
    }

    func restoreCacheIfPossible(cacheKey: SwiftPMCacheKey, storage: some FrameworkCacheStorage) async -> RestoreResult {
        do {
            if try await storage.existsValidCache(for: cacheKey) {
                try await storage.fetchArtifacts(for: cacheKey, to: outputDirectory)
                return .succeeded
            } else {
                return .noCache
            }
        } catch {
            return .failed(error as? LocalizedError)
        }
    }

    func calculateCacheKey(of target: CacheTarget) async throws -> SwiftPMCacheKey {
        try await calculateCacheKey(of: target, dependencyCacheKeyChecksums: [])
    }

    func calculateCacheKeys(for graph: DependencyGraph<CacheTarget>) async throws -> [CacheTarget: SwiftPMCacheKey] {
        var cacheKeys: [CacheTarget: SwiftPMCacheKey] = [:]

        func calculateCacheKeyRecursively(for node: DependencyGraph<CacheTarget>.Node) async throws {
            if cacheKeys[node.value] != nil {
                return
            }

            for child in node.children {
                try await calculateCacheKeyRecursively(for: child)
            }

            let dependencyChecksums = try node.children.map { child in
                let childCacheKey = cacheKeys[child.value]!
                return DependencyCacheKeyChecksum(
                    targetName: child.value.buildProduct.target.name,
                    checksum: try childCacheKey.calculateChecksum()
                )
            }
            cacheKeys[node.value] = try await calculateCacheKey(
                of: node.value,
                dependencyCacheKeyChecksums: dependencyChecksums
            )
        }

        for node in graph.allNodes {
            try await calculateCacheKeyRecursively(for: node)
        }

        return cacheKeys
    }

    private func calculateCacheKey(
        of target: CacheTarget,
        dependencyCacheKeyChecksums: [DependencyCacheKeyChecksum]
    ) async throws -> SwiftPMCacheKey {
        let package = target.buildProduct.package

        let localPackageCanonicalLocation: String? = switch package.resolvedPackageKind {
        case .fileSystem, .localSourceControl:
            package.canonicalPackageLocation.description
        case .root, .remoteSourceControl, .registry:
            nil
        }

        let pinState = try await retrievePinState(package: package)

        let targetName = target.buildProduct.target.name
        let buildOptions = target.buildOptions
        guard let clangVersion = try await ClangChecker().fetchClangVersion() else {
            throw Error.compilerVersionNotDetected
        } // TODO DI
        guard let xcodeVersion = try await XcodeVersionFetcher().fetchXcodeVersion() else {
            throw Error.xcodeVersionNotDetected
        }
        return SwiftPMCacheKey(
            localPackageCanonicalLocation: localPackageCanonicalLocation,
            pin: pinState,
            targetName: targetName,
            buildOptions: buildOptions,
            clangVersion: clangVersion,
            xcodeVersion: xcodeVersion,
            scipioVersion: currentScipioVersion,
            dependencyCacheKeyChecksums: dependencyCacheKeyChecksums
        )
    }

    private func retrievePinState(package: ResolvedPackage) async throws -> Pin.State {
        if let pinState = package.pinState {
            return pinState
        }

        guard let pinState = await package.makePinStateFromRevision() else {
            throw Error.revisionNotDetected(package.manifest.name)
        }

        return pinState
    }

    private func versionFilePath(for targetName: String) -> URL {
        outputDirectory.appendingPathComponent(versionFileName(for: targetName))
    }

    private func versionFileName(for targetName: String) -> String {
        ".\(targetName).version"
    }
}

public struct VersionFileDecoder {
    private let fileSystem: any FileSystem

    public init(fileSystem: any FileSystem = LocalFileSystem.default) {
        self.fileSystem = fileSystem
    }

    public func decode(versionFile: URL) throws -> SwiftPMCacheKey {
        let contents = try fileSystem.readFileContents(versionFile)
        return try jsonDecoder.decode(SwiftPMCacheKey.self, from: contents)
    }
}

extension ResolvedPackage {
    fileprivate func makePinStateFromRevision() async -> Pin.State? {
        let executor = GitExecutor(path: URL(filePath: path))

        guard let tag = try? await executor.fetchCurrentTag(),
              let version = Version(tag: tag),
              let revision = try? await executor.fetchCurrentRevision()
        else {
            return nil
        }

        // TODO: Even though the version requirement already covers the vast majority of cases,
        // supporting `branch` and `revision` requirements should, in theory, also be possible.
        return Pin.State(
            revision: revision,
            version: version.description
        )
    }
}

private struct GitExecutor<E: Executor> {
    let path: URL
    let executor: E

    init(path: URL, executor: E = ProcessExecutor()) {
        self.path = path
        self.executor = executor
    }

    func fetchCurrentTag() async throws -> String {
        let arguments = [
            "/usr/bin/xcrun",
            "git",
            "-C",
            path.path(percentEncoded: false),
            "describe",
            "--exact-match",
            "--tags",
        ]
        return try await executor.execute(arguments)
            .unwrapOutput()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func fetchCurrentRevision() async throws -> String {
        let arguments = [
            "/usr/bin/xcrun",
            "git",
            "-C",
            path.path(percentEncoded: false),
            "rev-parse",
            "--verify",
            "HEAD",
        ]
        return try await executor.execute(arguments)
            .unwrapOutput()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
