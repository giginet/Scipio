import Foundation
import ScipioStorage

struct LocalDiskCacheStorage: CacheStorage {
    private let fileSystem: any FileSystem

    var parallelNumber: Int? { nil }

    enum Error: Swift.Error {
        case cacheDirectoryIsNotFound
    }

    private let baseURL: URL?

    /// - Parameters:
    ///   - baseURL: The base url for the local disk cache. When it is nil, the system cache directory (`~/Library/Caches`) will be used.
    init(baseURL: URL?, fileSystem: FileSystem = LocalFileSystem.default) {
        self.baseURL = baseURL
        self.fileSystem = fileSystem
    }

    private func buildBaseDirectoryPath() async throws -> URL {
        let cacheDir: URL
        if let baseURL {
            cacheDir = baseURL
        } else {
            guard let systemCacheDir = await fileSystem.cachesDirectory else {
                throw Error.cacheDirectoryIsNotFound
            }
            cacheDir = systemCacheDir
        }
        return cacheDir.appendingPathComponent("Scipio")
    }

    private func xcFrameworkFileName(for cacheKey: some CacheKey) -> String {
        "\(cacheKey.targetName.packageNamed()).xcframework"
    }

    private func cacheFrameworkPath(for cacheKey: some CacheKey) async throws -> URL {
        let baseDirectory = try await buildBaseDirectoryPath()
        let checksum = try cacheKey.calculateChecksum()
        return baseDirectory
            .appendingPathComponent(cacheKey.targetName.packageNamed())
            .appendingPathComponent(checksum)
            .appendingPathComponent(xcFrameworkFileName(for: cacheKey))
    }

    func existsValidCache(for cacheKey: some CacheKey) async -> Bool {
        do {
            let xcFrameworkPath = try await cacheFrameworkPath(for: cacheKey)
            return await fileSystem.exists(xcFrameworkPath)
        } catch {
            return false
        }
    }

    func cacheFramework(_ frameworkPath: URL, for cacheKey: some CacheKey) async {
        do {
            let destination = try await cacheFrameworkPath(for: cacheKey)
            let directoryPath = destination.deletingLastPathComponent()

            try await fileSystem.createDirectory(directoryPath, recursive: true)
            try await fileSystem.copy(from: frameworkPath, to: destination)
        } catch {
            // ignore error
        }
    }

    func fetchArtifacts(for cacheKey: some CacheKey, to destinationDir: URL) async throws {
        let source = try await cacheFrameworkPath(for: cacheKey)
        let destination = destinationDir.appendingPathComponent(xcFrameworkFileName(for: cacheKey))
        try await fileSystem.copy(from: source, to: destination)
    }
}
