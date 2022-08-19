import Foundation
import TSCUtility
import PackageGraph
import TSCBasic

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
        return regex.matches(in: outputString, range: NSMakeRange(0, outputString.utf16.count)).compactMap { match -> String? in
            guard let version = match.captured(by: "version", in: outputString) else { return nil }
            return version
        }.first
    }
}

struct CacheKey: Hashable, Codable, Equatable {
    var targetName: String
    var revision: String
    var buildOptions: BuildOptions
    var clangVersion: String
}

protocol CacheStorage {
    func existsValidCache(for target: ResolvedTarget, cacheKey: CacheKey) async throws -> Bool
    func generateCache(for target: ResolvedTarget, cacheKey: CacheKey) async throws
    func fetchArtifacts(for target: ResolvedTarget, cacheKey: CacheKey, to destination: AbsolutePath) async throws
}

struct ProjectCacheStorage: CacheStorage {
    private let outputDirectory: AbsolutePath
    private let fileSystem: any FileSystem

    init(outputDirectory: AbsolutePath, fileSystem: any FileSystem = localFileSystem) {
        self.outputDirectory = outputDirectory
        self.fileSystem = fileSystem
    }

    func existsValidCache(for target: ResolvedTarget, cacheKey: CacheKey) async throws -> Bool {
        let versionFilePath = versionFilePath(for: target)
        guard fileSystem.exists(versionFilePath) else { return false }
        let decoder = JSONDecoder()
        do {
            let versionFileKey = try decoder.decode(path: versionFilePath, fileSystem: fileSystem, as: CacheKey.self)
            return versionFileKey == cacheKey
        } catch {
            return false
        }
    }

    func fetchArtifacts(for target: ResolvedTarget, cacheKey: CacheKey, to destination: AbsolutePath) async throws {
        guard outputDirectory != destination else {
            return
        }
        let versionFileName = versionFileName(for: target)
        try fileSystem.move(from: versionFilePath(for: target),
                            to: destination.appending(component: versionFileName))
    }

    func generateCache(for target: ResolvedTarget, cacheKey: CacheKey) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(cacheKey)
        let versionFilePath = versionFilePath(for: target)
        try fileSystem.writeFileContents(versionFilePath, data: data)
    }

    private func versionFileName(for target: ResolvedTarget) -> String {
        ".\(target.name).version"
    }

    private func versionFilePath(for target: ResolvedTarget) -> AbsolutePath {
        outputDirectory.appending(component: versionFileName(for: target))
    }
}

struct CacheSystem<Storage: CacheStorage> {
    private let rootPackage: Package
    private let buildOptions: BuildOptions
    private let storage: Storage

    enum Error: LocalizedError {
        case revisionNotDetected(String)
        case compilerVersionNotDetected

        var errorDescription: String? {
            switch self {
            case .revisionNotDetected:
                return "Repository version is not detected."
            case .compilerVersionNotDetected:
                return "Compiler version not detected. Please check your environment"
            }
        }
    }

    init(rootPackage: Package, buildOptions: BuildOptions, storage: Storage) {
        self.rootPackage = rootPackage
        self.buildOptions = buildOptions
        self.storage = storage
    }

    func generateVersionFile(subPackage: ResolvedPackage, target: ResolvedTarget) async throws {
        let cacheKey = try await calculateCacheKey(package: subPackage, target: target)
        try await storage.generateCache(for: target, cacheKey: cacheKey)
    }

    func existsValidCache(subPackage: ResolvedPackage, target: ResolvedTarget) async throws -> Bool {
        let cacheKey = try await calculateCacheKey(package: subPackage, target: target)
        return try await storage.existsValidCache(for: target, cacheKey: cacheKey)
    }

    func fetchArtifacts(subPackage: ResolvedPackage, target: ResolvedTarget, to destination: AbsolutePath) async throws {
        let cacheKey = try await calculateCacheKey(package: subPackage, target: target)
        try await storage.fetchArtifacts(for: target, cacheKey: cacheKey, to: destination)
    }

    private func calculateCacheKey(package: ResolvedPackage, target: ResolvedTarget) async throws -> CacheKey {
        let targetName = target.name
        guard let revision = package.manifest.version?.description ?? package.manifest.revision else {
            throw Error.revisionNotDetected(targetName)
        }
        let buildOptions = buildOptions
        guard let clangVersion = try await ClangChecker().fetchClangVersion() else { throw Error.compilerVersionNotDetected } // TODO DI
        return CacheKey(targetName: targetName, revision: revision, buildOptions: buildOptions, clangVersion: clangVersion)
    }
}

extension CacheKey {
    var sha256Hash: String {
        return SHA256().hash(.init(hashValue)).sha256Checksum
    }
}
