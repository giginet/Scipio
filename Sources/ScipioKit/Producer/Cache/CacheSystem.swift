import Foundation
import TSCBasic
import struct TSCUtility.Version
import PackageGraph
import Algorithms

private let jsonEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    return encoder
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

extension PinsStore.PinState: Hashable {
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

public struct CacheKey: Hashable, Codable, Equatable {
    public var targetName: String
    public var pin: PinsStore.PinState
    var buildOptions: BuildOptions
    public var clangVersion: String
}

public protocol CacheStorage {
    func existsValidCache(for cacheKey: CacheKey) async throws -> Bool
    func fetchArtifacts(for cacheKey: CacheKey, to destinationDir: URL) async throws
    func cacheFramework(_ frameworkPath: URL, for cacheKey: CacheKey) async throws
    var taskConcurrency: Int? { get }
}

extension CacheStorage {
    public var taskConcurrency: Int? {
        nil
    }
}

struct CacheSystem {
    static let defaultTaskConcurrency = 8
    private let descriptionPackage: DescriptionPackage
    private let outputDirectory: URL
    private let storage: (any CacheStorage)?
    private let fileSystem: any FileSystem

    struct CacheTarget: Hashable {
        var buildProduct: BuildProduct
        var buildOptions: BuildOptions
    }

    enum Error: LocalizedError {
        case revisionNotDetected(String)
        case compilerVersionNotDetected
        case couldNotReadVersionFile(URL)

        var errorDescription: String? {
            switch self {
            case .revisionNotDetected(let packageName):
                return "Repository version is not detected for \(packageName)."
            case .compilerVersionNotDetected:
                return "Compiler version not detected. Please check your environment"
            case .couldNotReadVersionFile(let path):
                return "Could not read VersionFile \(path.path)"
            }
        }
    }

    init(
        descriptionPackage: DescriptionPackage,
        outputDirectory: URL,
        storage: (any CacheStorage)?,
        fileSystem: any FileSystem = localFileSystem
    ) {
        self.descriptionPackage = descriptionPackage
        self.outputDirectory = outputDirectory
        self.storage = storage
        self.fileSystem = fileSystem
    }

    func cacheFrameworks(_ targets: Set<CacheTarget>) async {
        let chunked = targets.chunks(ofCount: storage?.taskConcurrency ?? CacheSystem.defaultTaskConcurrency)

        for chunk in chunked {
            await withTaskGroup(of: Void.self) { group in
                for target in chunk {
                    group.addTask {
                        let frameworkPath = outputDirectory.appendingPathComponent(target.buildProduct.frameworkName)
                        do {
                            try await cacheFramework(target, at: frameworkPath)
                        } catch {
                            logger.warning("⚠️ Can't create caches for \(frameworkPath.path)")
                        }
                    }
                }
                await group.waitForAll()
            }
        }
    }

    private func cacheFramework(_ target: CacheTarget, at frameworkPath: URL) async throws {
        let cacheKey = try await calculateCacheKey(of: target)

        try await storage?.cacheFramework(frameworkPath, for: cacheKey)
    }

    func generateVersionFile(for target: CacheTarget) async throws {
        let cacheKey = try await calculateCacheKey(of: target)

        let data = try jsonEncoder.encode(cacheKey)
        let versionFilePath = outputDirectory.appendingPathComponent(versionFileName(for: target.buildProduct.target.name))
        try fileSystem.writeFileContents(versionFilePath.absolutePath, data: data)
    }

    func existsValidCache(target: CacheTarget) async -> Bool {
        do {
            let cacheKey = try await calculateCacheKey(of: target)
            let versionFilePath = versionFilePath(for: cacheKey.targetName)
            guard fileSystem.exists(versionFilePath.absolutePath) else { return false }
            let decoder = JSONDecoder()
            guard let contents = try? fileSystem.readFileContents(versionFilePath.absolutePath).contents else {
                throw Error.couldNotReadVersionFile(versionFilePath)
            }
            let versionFileKey = try decoder.decode(CacheKey.self, from: Data(contents))
            return versionFileKey == cacheKey
        } catch {
            return false
        }
    }

    func restoreCacheIfPossible(target: CacheTarget) async -> Bool {
        guard let storage = storage else { return false }
        do {
            let cacheKey = try await calculateCacheKey(of: target)
            if try await storage.existsValidCache(for: cacheKey) {
                try await storage.fetchArtifacts(for: cacheKey, to: outputDirectory)
                return true
            } else {
                return false
            }
        } catch {
            return false
        }
    }

    private func fetchArtifacts(target: CacheTarget, to destination: URL) async throws {
        guard let storage = storage else { return }
        let cacheKey = try await calculateCacheKey(of: target)
        try await storage.fetchArtifacts(for: cacheKey, to: destination)
    }

    private func calculateCacheKey(of target: CacheTarget) async throws -> CacheKey {
        let targetName = target.buildProduct.target.name
        let pin = try retrievePin(product: target.buildProduct)
        let buildOptions = target.buildOptions
        guard let clangVersion = try await ClangChecker().fetchClangVersion() else { throw Error.compilerVersionNotDetected } // TODO DI
        return CacheKey(
            targetName: targetName,
            pin: pin.state,
            buildOptions: buildOptions,
            clangVersion: clangVersion
        )
    }

    private func retrievePin(product: BuildProduct) throws -> PinsStore.Pin {
        let pinsStore = try descriptionPackage.workspace.pinsStore.load()
        guard let pin = pinsStore.pinsMap[product.package.identity] else {
            throw Error.revisionNotDetected(product.package.manifest.displayName)
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

extension CacheKey {
    public func calculateChecksum() throws -> String {
        let data = try jsonEncoder.encode(self)
        return SHA256().hash(ByteString(data)).hexadecimalRepresentation
    }
}
