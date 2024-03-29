import Foundation
import PackageGraph
import TSCBasic

public struct LocalCacheStorage: CacheStorage {
    private let fileSystem: any FileSystem

    enum Error: Swift.Error {
        case cacheDirectoryIsNotFound
    }

    public enum CacheDirectory {
        case system
        case custom(URL)
    }

    private let cacheDirectroy: CacheDirectory

    public init(cacheDirectory: CacheDirectory = .system, fileSystem: FileSystem = localFileSystem) {
        self.cacheDirectroy = cacheDirectory
        self.fileSystem = fileSystem
    }

    private func buildBaseDirectoryPath() throws -> URL {
        let cacheDir: URL
        switch cacheDirectroy {
        case .system:
            guard let systemCacheDir = fileSystem.cachesDirectory else {
                throw Error.cacheDirectoryIsNotFound
            }
            cacheDir = systemCacheDir.asURL
        case .custom(let customPath):
            cacheDir = customPath
        }
        return cacheDir.appendingPathComponent("Scipio")
    }

    private func xcFrameworkFileName(for cacheKey: CacheKey) -> String {
        "\(cacheKey.targetName.packageNamed()).xcframework"
    }

    private func cacheFrameworkPath(for cacheKey: CacheKey) throws -> URL {
        let baseDirectory = try buildBaseDirectoryPath()
        let checksum = try cacheKey.calculateChecksum()
        return baseDirectory
            .appendingPathComponent(cacheKey.targetName.packageNamed())
            .appendingPathComponent(checksum)
            .appendingPathComponent(xcFrameworkFileName(for: cacheKey))
    }

    public func existsValidCache(for cacheKey: CacheKey) async -> Bool {
        do {
            let xcFrameworkPath = try cacheFrameworkPath(for: cacheKey)
            return fileSystem.exists(xcFrameworkPath.absolutePath)
        } catch {
            return false
        }
    }

    public func cacheFramework(_ frameworkPath: URL, for cacheKey: CacheKey) async {
        do {
            let destination = try cacheFrameworkPath(for: cacheKey)
            let directoryPath = destination.deletingLastPathComponent()

            try fileSystem.createDirectory(directoryPath.absolutePath, recursive: true)
            try fileSystem.copy(from: frameworkPath.absolutePath, to: destination.absolutePath)
        } catch {
            // ignore error
        }
    }

    public func fetchArtifacts(for cacheKey: CacheKey, to destinationDir: URL) async throws {
        let source = try cacheFrameworkPath(for: cacheKey)
        let destination = destinationDir.appendingPathComponent(xcFrameworkFileName(for: cacheKey))
        try fileSystem.copy(from: source.absolutePath, to: destination.absolutePath)
    }
}
