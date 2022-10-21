import Foundation
import TSCUtility
import PackageGraph
import TSCBasic

public struct LocalCacheStorage: CacheStorage {
    private let fileSystem: any ScipioKit.FileSystem

    enum Error: Swift.Error {
        case cacheDirectoryIsNotFound
    }

    public enum CacheDirectory {
        case system
        case custom(AbsolutePath)
    }

    private let cacheDirectroy: CacheDirectory

    public init(cacheDirectory: CacheDirectory = .system, fileSystem: ScipioKit.FileSystem = ScipioKit.localFileSystem) {
        self.cacheDirectroy = cacheDirectory
        self.fileSystem = fileSystem
    }

    private func buildBaseDirectoryPath() throws -> AbsolutePath {
        let cacheDir: Foundation.URL
        switch cacheDirectroy {
        case .system:
            guard let systemCacheDir = fileSystem.cachesDirectory else {
                throw Error.cacheDirectoryIsNotFound
            }
            cacheDir = systemCacheDir
        case .custom(let customPath):
            cacheDir = customPath.asURL
        }
        return AbsolutePath(cacheDir.appendingPathComponent("Scipio").path)
    }

    private func xcFrameworkFileName(for cacheKey: CacheKey) -> String {
        "\(cacheKey.targetName.packageNamed()).xcframework"
    }

    private func cacheFrameworkPath(for cacheKey: CacheKey) throws -> AbsolutePath {
        let baseDirectory = try buildBaseDirectoryPath()
        let checksum = try cacheKey.calculateChecksum()
        return baseDirectory.appending(components: cacheKey.targetName.packageNamed(), checksum, xcFrameworkFileName(for: cacheKey))
    }

    public func existsValidCache(for cacheKey: CacheKey) async -> Bool {
        do {
            let xcFrameworkPath = try cacheFrameworkPath(for: cacheKey)
            return fileSystem.exists(xcFrameworkPath.asURL)
        } catch {
            return false
        }
    }

    public func cacheFramework(_ frameworkPath: TSCBasic.AbsolutePath, for cacheKey: CacheKey) async {
        do {
            let destination = try cacheFrameworkPath(for: cacheKey)
            let directoryPath = AbsolutePath(destination.dirname)

            try fileSystem.createDirectory(directoryPath.asURL, recursive: true)
            try fileSystem.copy(at: frameworkPath.asURL, to: destination.asURL)
        } catch {
            // ignore error
        }
    }

    public func fetchArtifacts(for cacheKey: CacheKey, to destinationDir: TSCBasic.AbsolutePath) async throws {
        let source = try cacheFrameworkPath(for: cacheKey)
        let destination = destinationDir.appending(component: xcFrameworkFileName(for: cacheKey))
        try fileSystem.copy(at: source.asURL, to: destination.asURL)
    }
}
