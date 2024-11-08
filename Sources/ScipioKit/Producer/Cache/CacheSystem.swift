import Foundation
import ScipioStorage
import TSCBasic
import struct TSCUtility.Version
import Algorithms
// We may drop this annotation in SwiftPM's future release
@preconcurrency import PackageGraph
import PackageModel
import SourceControl

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
        // TODO Use modern regex
        let regex = try! NSRegularExpression(pattern: "Apple\\sclang\\sversion\\s.+\\s\\((?<version>.+)\\)")
        return regex.matches(in: outputString, range: NSRange(location: 0, length: outputString.utf16.count)).compactMap { match -> String? in
            guard let version = match.captured(by: "version", in: outputString) else { return nil }
            return version
        }.first
    }
}

extension PinsStore.PinState: Codable {
    enum Key: CodingKey {
        case revision
        case branch
        case version
    }

    public func encode(to encoder: Encoder) throws {
        var versionContainer = encoder.container(keyedBy: Key.self)
        switch self {
        case .version(let version, let revision):
            try versionContainer.encode(version.description, forKey: .version)
            try versionContainer.encode(revision, forKey: .revision)
        case .revision(let revision):
            try versionContainer.encode(revision, forKey: .revision)
        case .branch(let branchName, let revision):
            try versionContainer.encode(branchName, forKey: .branch)
            try versionContainer.encode(revision, forKey: .revision)
        }
    }

    public init(from decoder: Decoder) throws {
        let decoder = try decoder.container(keyedBy: Key.self)
        if decoder.contains(.branch) {
            let branchName = try decoder.decode(String.self, forKey: .branch)
            let revision = try decoder.decode(String.self, forKey: .revision)
            self = .branch(name: branchName, revision: revision)
        } else if decoder.contains(.version) {
            let version = try decoder.decode(Version.self, forKey: .version)
            let revision = try decoder.decode(String?.self, forKey: .revision)
            self = .version(version, revision: revision)
        } else {
            let revision = try decoder.decode(String.self, forKey: .revision)
            self = .revision(revision)
        }
    }
}

extension PinsStore.PinState: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .revision(let revision):
            hasher.combine(revision)
        case .version(let version, let revision):
            hasher.combine(version)
            hasher.combine(revision)
        case .branch(let branchName, let revision):
            hasher.combine(branchName)
            hasher.combine(revision)
        }
    }
}

public struct SwiftPMCacheKey: CacheKey {
    public var targetName: String
    public var pin: PinsStore.PinState
    var buildOptions: BuildOptions
    public var clangVersion: String
    public var xcodeVersion: XcodeVersion
    public var scipioVersion: String?
}

struct CacheSystem: Sendable {
    static let defaultParalellNumber = 8
    private let pinsStore: PinsStore
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
        pinsStore: PinsStore,
        outputDirectory: URL,
        fileSystem: any FileSystem = localFileSystem
    ) {
        self.pinsStore = pinsStore
        self.outputDirectory = outputDirectory
        self.fileSystem = fileSystem
    }

    func cacheFrameworks(_ targets: Set<CacheTarget>, storages: [any CacheStorage]?) async {
        guard let storages, !storages.isEmpty else {
            // About `CacheMode.project` which is not tied to any (external) storages, we don't need to do anything.
            // The built frameworks under the project themselves are treated as valid caches.
            return
        }

        for storage in storages {
            await cacheFrameworks(targets, storage: storage)
        }
    }

    private func cacheFrameworks(_ targets: Set<CacheTarget>, storage: any CacheStorage) async {
        let chunked = targets.chunks(ofCount: storage.parallelNumber ?? CacheSystem.defaultParalellNumber)

        for chunk in chunked {
            await withTaskGroup(of: Void.self) { group in
                for target in chunk {
                    let frameworkName = target.buildProduct.frameworkName
                    group.addTask {
                        let frameworkPath = outputDirectory.appendingPathComponent(frameworkName)
                        do {
                            logger.info(
                                "🚀 Cache \(frameworkName) to cache storage: \(storage)",
                                metadata: .color(.green)
                            )
                            try await cacheFramework(target, at: frameworkPath, storage: storage)
                        } catch {
                            logger.warning("⚠️ Can't create caches for \(frameworkPath.path)")
                        }
                    }
                }
                await group.waitForAll()
            }
        }
    }

    private func cacheFramework(_ target: CacheTarget, at frameworkPath: URL, storage: any CacheStorage) async throws {
        let cacheKey = try await calculateCacheKey(of: target)

        try await storage.cacheFramework(frameworkPath, for: cacheKey)
    }

    func generateVersionFile(for target: CacheTarget) async throws {
        let cacheKey = try await calculateCacheKey(of: target)

        let data = try jsonEncoder.encode(cacheKey)
        let versionFilePath = outputDirectory.appendingPathComponent(versionFileName(for: target.buildProduct.target.name))
        try fileSystem.writeFileContents(
            versionFilePath.absolutePath.spmAbsolutePath,
            data: data
        )
    }

    func existsValidCache(cacheKey: SwiftPMCacheKey) async -> Bool {
        do {
            let versionFilePath = versionFilePath(for: cacheKey.targetName)
            guard fileSystem.exists(versionFilePath.absolutePath) else { return false }
            let decoder = JSONDecoder()
            guard let contents = try? fileSystem.readFileContents(versionFilePath.absolutePath).contents else {
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

    func restoreCacheIfPossible(target: CacheTarget, storage: any CacheStorage) async -> RestoreResult {
        do {
            let cacheKey = try await calculateCacheKey(of: target)
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
        let targetName = target.buildProduct.target.name
        let pin = try retrievePin(package: target.buildProduct.package)
        let buildOptions = target.buildOptions
        guard let clangVersion = try await ClangChecker().fetchClangVersion() else {
            throw Error.compilerVersionNotDetected
        } // TODO DI
        guard let xcodeVersion = try await XcodeVersionFetcher().fetchXcodeVersion() else {
            throw Error.xcodeVersionNotDetected
        }
        return SwiftPMCacheKey(
            targetName: targetName,
            pin: pin.state,
            buildOptions: buildOptions,
            clangVersion: clangVersion,
            xcodeVersion: xcodeVersion,
            scipioVersion: currentScipioVersion
        )
    }

    private func retrievePin(package: ResolvedPackage) throws -> PinsStore.Pin {
        guard let pin = pinsStore.pins[package.identity] ?? package.makePinFromRevision() else {
            throw Error.revisionNotDetected(package.manifest.displayName)
        }
        return pin
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

    public init(fileSystem: any FileSystem = localFileSystem) {
        self.fileSystem = fileSystem
    }

    public func decode(versionFile: URL) throws -> SwiftPMCacheKey {
        try jsonDecoder.decode(
            path: versionFile.absolutePath.spmAbsolutePath,
            fileSystem: fileSystem,
            as: SwiftPMCacheKey.self
        )
    }
}

extension ResolvedPackage {
    fileprivate func makePinFromRevision() -> PinsStore.Pin? {
        let repository = GitRepository(path: path)

        guard let tag = repository.getCurrentTag(), let version = Version(tag: tag) else {
            return nil
        }

        // TODO: Even though the version requirement already covers the vast majority of cases,
        // supporting `branch` and `revision` requirements should, in theory, also be possible.
        return PinsStore.Pin(
            packageRef: PackageReference(
                identity: identity,
                kind: manifest.packageKind
            ),
            state: .version(
                version,
                revision: try? repository.getCurrentRevision().identifier
            )
        )
    }
}
