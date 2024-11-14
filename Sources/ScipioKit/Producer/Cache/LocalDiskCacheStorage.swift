import Foundation
import ScipioStorage
import PackageGraph
import TSCBasic

struct LocalDiskCacheStorage: CacheStorage {
    private let fileSystem: any FileSystem

    var parallelNumber: Int? { nil }

    enum Error: Swift.Error {
        case cacheDirectoryIsNotFound
    }

    private let baseURL: URL?

    /// - Parameters:
    ///   - baseURL: The base url for the local disk cache. When it is nil, the system cache directory (`~/Library/Caches`) will be used.
    init(baseURL: URL? = nil, fileSystem: FileSystem = localFileSystem) {
        self.baseURL = baseURL
        self.fileSystem = fileSystem
    }

    private func buildBaseDirectoryPath() throws -> URL {
        let cacheDir: URL
        if let baseURL {
            cacheDir = baseURL
        } else {
            guard let systemCacheDir = fileSystem.cachesDirectory else {
                throw Error.cacheDirectoryIsNotFound
            }
            cacheDir = systemCacheDir.asURL
        }
        return cacheDir.appendingPathComponent("Scipio")
    }

    private func xcFrameworkFileName(for cacheKey: some CacheKey) -> String {
        "\(cacheKey.targetName.packageNamed()).xcframework"
    }

    private func cacheFrameworkPath(for cacheKey: some CacheKey) throws -> URL {
        let baseDirectory = try buildBaseDirectoryPath()
        let checksum = try cacheKey.calculateChecksum()
        return baseDirectory
            .appendingPathComponent(cacheKey.targetName.packageNamed())
            .appendingPathComponent(checksum)
            .appendingPathComponent(xcFrameworkFileName(for: cacheKey))
    }

    func existsValidCache(for cacheKey: some CacheKey) async -> Bool {
        do {
            let xcFrameworkPath = try cacheFrameworkPath(for: cacheKey)
            return fileSystem.exists(xcFrameworkPath.absolutePath)
        } catch {
            return false
        }
    }

    func cacheFramework(_ frameworkPath: URL, for cacheKey: some CacheKey) async {
        do {
            let destination = try cacheFrameworkPath(for: cacheKey)
            let directoryPath = destination.deletingLastPathComponent()

            try fileSystem.createDirectory(directoryPath.absolutePath, recursive: true)
            try fileSystem.copy(from: frameworkPath.absolutePath, to: destination.absolutePath)
        } catch {
            // ignore error
        }
    }

    func fetchArtifacts(for cacheKey: some CacheKey, to destinationDir: URL) async throws {
        let source = try cacheFrameworkPath(for: cacheKey)
        let destination = destinationDir.appendingPathComponent(xcFrameworkFileName(for: cacheKey))
        try fileSystem.copy(from: source.absolutePath, to: destination.absolutePath)
    }
}
