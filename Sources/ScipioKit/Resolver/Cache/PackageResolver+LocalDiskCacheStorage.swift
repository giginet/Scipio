import Foundation
import CacheStorage
import ScipioKitCore
import struct UniformTypeIdentifiers.UTType

extension PackageResolver {
    struct LocalDiskCacheStorage: ResolvedPackagesCacheStorage {
        private let jsonDecoder = JSONDecoder()
        private let jsonEncoder = JSONEncoder()
        private let baseURL: URL?
        private let fileSystem: any FileSystem

        init(
            baseURL: URL?,
            fileSystem: some FileSystem = LocalFileSystem.default,
        ) {
            self.baseURL = baseURL
            self.fileSystem = fileSystem
        }

        func existsValidCache(for originHash: String) async throws -> Bool {
            try fileSystem.exists(resolveCacheFile(from: originHash))
        }

        func fetchResolvedPackages(for originHash: String) async throws -> [ResolvedPackage] {
            let cacheFileURL = try resolveCacheFile(from: originHash)
            guard fileSystem.exists(cacheFileURL) else {
                // If the originHash differs between the current Package.resolved and the cached one, delete it
                try? fileSystem.removeFileTree(cacheFileURL.deletingLastPathComponent())
                return []
            }

            let data = try fileSystem.readFileContents(cacheFileURL)
            return try jsonDecoder.decode([ResolvedPackage].self, from: data)
        }

        func cacheResolvedPackages(_ resolvedPackages: [ResolvedPackage], for originHash: String) async throws {
            let cacheFileURL = try resolveCacheFile(from: originHash)
            let data = try jsonEncoder.encode(resolvedPackages)
            try fileSystem.writeFileContents(cacheFileURL, data: data)
        }

        private func resolveCacheFile(from originHash: String) throws -> URL {
            try buildBaseURL().appendingPathComponent("ResolvedPackages_\(originHash)", conformingTo: .json)
        }

        private func buildBaseURL() throws -> URL {
            let cacheDir: URL
            if let baseURL {
                return baseURL
            } else {
                guard let systemCacheDir = fileSystem.cachesDirectory else {
                    throw Error.cacheDirectoryIsNotFound
                }
                return systemCacheDir.appending(components: "Scipio", "ResolvedPackages")
            }
        }

        enum Error: Swift.Error {
            case cacheDirectoryIsNotFound
        }
    }
}
