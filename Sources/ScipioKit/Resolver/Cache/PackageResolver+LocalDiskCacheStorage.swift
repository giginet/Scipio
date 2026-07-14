import Foundation
import CacheStorage
import ScipioKitCore
import struct UniformTypeIdentifiers.UTType

extension PackageResolver {
    struct LocalDiskCacheStorage: ResolvedPackagesCacheStorage {
        private let jsonDecoder = JSONDecoder()
        private let jsonEncoder: JSONEncoder = {
            let encoder = JSONEncoder()
            // Sorted keys give identical bytes for identical input.
            encoder.outputFormatting = [.sortedKeys]
            return encoder
        }()
        private let baseURL: URL?
        private let fileSystem: any FileSystem

        var displayName: String {
            let cacheURLDescription = (try? buildBaseURL().path(percentEncoded: false)) ?? "unavailable"
            if let baseURL {
                return "\(Self.self)(baseURL: \(baseURL.path(percentEncoded: false)), cacheURL: \(cacheURLDescription))"
            } else {
                return "\(Self.self)(systemCacheURL: \(cacheURLDescription))"
            }
        }

        /// - Parameters:
        ///   - baseURL: The base url for the local disk cache. When it is nil, the system cache directory (`~/Library/Caches`) will be used.
        init(
            baseURL: URL?,
            fileSystem: some FileSystem = LocalFileSystem.default,
        ) {
            self.baseURL = baseURL
            self.fileSystem = fileSystem
        }

        /// Restorability is part of validity: the share step in `CacheSystem`
        /// skips storages reporting a valid cache, so a legacy or corrupted
        /// file must answer false here to get overwritten.
        func existsValidCache(for originHash: String) async throws -> Bool {
            let cacheFileURL = try resolveCacheFile(from: originHash)
            guard fileSystem.exists(cacheFileURL) else {
                return false
            }
            return try loadRestorablePackages(from: cacheFileURL) != nil
        }

        func fetchResolvedPackages(for originHash: String) async throws -> [ResolvedPackage] {
            let cacheFileURL = try resolveCacheFile(from: originHash)
            guard fileSystem.exists(cacheFileURL) else {
                // If the originHash differs between the current Package.resolved and the cached one, delete it
                try? fileSystem.removeFileTree(cacheFileURL.deletingLastPathComponent())
                return []
            }

            return try loadRestorablePackages(from: cacheFileURL) ?? []
        }

        /// Returns restored packages, or discards an unsupported/corrupted cache and returns nil.
        private func loadRestorablePackages(from cacheFileURL: URL) throws -> [ResolvedPackage]? {
            let data = try fileSystem.readFileContents(cacheFileURL)
            do {
                let snapshot = try jsonDecoder.decode(ResolvedPackagesSnapshot.self, from: data)
                return try snapshot.restoreResolvedPackages()
            } catch {
                let cacheFilePath = cacheFileURL.path(percentEncoded: false)
                logger.warning(
                    "⚠️ Discarding a resolved packages cache in an unsupported format at \(cacheFilePath): \(error)",
                    metadata: .color(.yellow)
                )
                do {
                    try fileSystem.removeFileTree(cacheFileURL)
                } catch {
                    logger.warning(
                        "⚠️ Failed to remove the unsupported cache file at \(cacheFilePath): \(error)",
                        metadata: .color(.yellow)
                    )
                }
                return nil
            }
        }

        func cacheResolvedPackages(_ resolvedPackages: [ResolvedPackage], for originHash: String) async throws {
            let cacheFileURL = try resolveCacheFile(from: originHash)
            let data = try jsonEncoder.encode(ResolvedPackagesSnapshot(resolvedPackages: resolvedPackages))
            try fileSystem.writeFileContents(cacheFileURL, data: data)
        }

        private func resolveCacheFile(from originHash: String) throws -> URL {
            try buildBaseURL().appendingPathComponent("ResolvedPackages_\(originHash)", conformingTo: .json)
        }

        private func buildBaseURL() throws -> URL {
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

extension PackageResolver.LocalDiskCacheStorage: Equatable {
    static func == (lhs: PackageResolver.LocalDiskCacheStorage, rhs: PackageResolver.LocalDiskCacheStorage) -> Bool {
        lhs.baseURL == rhs.baseURL
    }
}
