import Foundation
import TSCUtility
import PackageGraph
import TSCBasic

public struct LocalCacheStrategy: CacheStrategy {
    private let fileSystem: any FileSystem

    enum Error: Swift.Error {
        case cacheDirectoryIsNotFound
    }

    public init(fileSystem: FileSystem = localFileSystem) {
        self.fileSystem = fileSystem
    }

    private func buildBaseDirectoryPath() throws -> AbsolutePath {
        guard let cacheDir = fileSystem.cachesDirectory else {
            throw Error.cacheDirectoryIsNotFound
        }
        return cacheDir.appending(component: "Scipio")
    }

    private func xcFrameworkFileName(for cacheKey: CacheKey) -> String {
        "\(cacheKey.targetName).xcframework"
    }

    private func cacheFrameworkPath(for cacheKey: CacheKey) throws -> AbsolutePath {
        let targetName = cacheKey.targetName
        let baseDirectory = try buildBaseDirectoryPath()
        return baseDirectory.appending(components: targetName, cacheKey.sha256Hash, xcFrameworkFileName(for: cacheKey))
    }

    public func existsValidCache(for cacheKey: CacheKey) async -> Bool {
        do {
            let xcFrameworkPath = try cacheFrameworkPath(for: cacheKey)
            return fileSystem.exists(xcFrameworkPath)
        } catch {
            return false
        }
    }

    public func cacheFramework(_ frameworkPath: TSCBasic.AbsolutePath, for cacheKey: CacheKey) async throws {
        let destination = try cacheFrameworkPath(for: cacheKey)
        let directoryPath = AbsolutePath(destination.dirname)
        try fileSystem.createDirectory(directoryPath, recursive: true)

        try fileSystem.copy(from: frameworkPath, to: destination)
    }

    public func fetchArtifacts(for cacheKey: CacheKey, to destinationDir: TSCBasic.AbsolutePath) async throws {
        let source = try cacheFrameworkPath(for: cacheKey)
        let destination = destinationDir.appending(component: xcFrameworkFileName(for: cacheKey))
        try fileSystem.copy(from: source, to: destination)
    }


}
