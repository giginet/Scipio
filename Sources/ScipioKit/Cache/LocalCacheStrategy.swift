import Foundation
import TSCUtility
import PackageGraph
import TSCBasic

struct LocalCacheStrategy: CacheStrategy {
    private let fileSystem: any FileSystem

    enum Error: Swift.Error {
        case cacheDirectoryIsNotFound
    }

    init(fileSystem: FileSystem = localFileSystem) {
        self.fileSystem = fileSystem
    }

    private func buildBaseDirectoryPath() throws -> AbsolutePath {
        guard let cacheDir = fileSystem.cachesDirectory else {
            throw Error.cacheDirectoryIsNotFound
        }
        return cacheDir.appending(component: "Scipio")
    }

    private func xcFrameworkFileName(for cacheKey: CacheKey) -> String {
        "\(cacheKey.targetName.packageNamed()).xcframework"
    }

    private func cacheFrameworkPath(for cacheKey: CacheKey) throws -> AbsolutePath {
        let baseDirectory = try buildBaseDirectoryPath()
        let checksum = try cacheKey.calculateChecksum()
        return baseDirectory.appending(components: cacheKey.targetName.packageNamed(), checksum, xcFrameworkFileName(for: cacheKey))
    }

    func existsValidCache(for cacheKey: CacheKey) async -> Bool {
        do {
            let xcFrameworkPath = try cacheFrameworkPath(for: cacheKey)
            return fileSystem.exists(xcFrameworkPath)
        } catch {
            return false
        }
    }

    func cacheFramework(_ frameworkPath: TSCBasic.AbsolutePath, for cacheKey: CacheKey) async throws {
        let destination = try cacheFrameworkPath(for: cacheKey)
        let directoryPath = AbsolutePath(destination.dirname)
        try fileSystem.createDirectory(directoryPath, recursive: true)

        try fileSystem.copy(from: frameworkPath, to: destination)
    }

    func fetchArtifacts(for cacheKey: CacheKey, to destinationDir: TSCBasic.AbsolutePath) async throws {
        let source = try cacheFrameworkPath(for: cacheKey)
        let destination = destinationDir.appending(component: xcFrameworkFileName(for: cacheKey))
        try fileSystem.copy(from: source, to: destination)
    }


}
