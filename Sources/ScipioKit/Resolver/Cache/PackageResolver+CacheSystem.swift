import Foundation
import AsyncOperations
import ScipioKitCore
import CacheStorage

extension PackageResolver {
    /// Manages caching and restoration of resolved packages across multiple storage backends.
    struct CacheSystem {
        static let defaultParallelNumber: UInt = 4
        private let fileSystem: any FileSystem
        private let packageLocator: any PackageLocator
        private let cachePolicies: [Runner.Options.ResolvedPackagesCachePolicy]

        init(
            fileSystem: some FileSystem,
            packageLocator: some PackageLocator,
            cachePolicies: [Runner.Options.ResolvedPackagesCachePolicy]
        ) {
            self.fileSystem = fileSystem
            self.packageLocator =  packageLocator
            self.cachePolicies = cachePolicies
        }

        /// Stores resolved packages to configured cache storages.
        func cacheResolvedPackages(
            _ resolvedPackages: [ResolvedPackage],
            for originHash: String
        ) async {
            let storages = cachePolicies.storages(for: .producer, packageLocator: packageLocator, fileSystem: fileSystem)
            guard !storages.isEmpty else { return }

            await storages.asyncForEach(numberOfConcurrentTasks: Self.defaultParallelNumber) { storage in
                logger.info("🚀 Cache resolved packages to cache storage: \(storage.displayName)")
                await self.cacheResolvedPackages(resolvedPackages, for: originHash, to: storage)
            }
        }

        /// Attempts to restore resolved packages from cache storages.
        func restoreCacheIfPossible(
            for originHash: String,
        ) async -> RestoreResult {
            let storages = cachePolicies.storages(for: .consumer, packageLocator: packageLocator, fileSystem: fileSystem)
            guard !storages.isEmpty else {
                return .noCache
            }

            logger.info(
                "▶️ Starting restoration of resolved packages from \(storages.count) cache storage(s)",
                metadata: .color(.green)
            )

            var errors: [any Error] = []

            for (index, storage) in storages.enumerated() {
                let storageName = storage.displayName
                let logSuffix = "[\(index)] \(storageName)"

                do {
                    let result = try await restoreCacheIfPossible(for: originHash, storage: storage)
                    if !result.isEmpty {
                        logger.info(
                            "✅ Restored resolved packages from cache storage: \(logSuffix)",
                            metadata: .color(.green)
                        )
                        // Found a cache. Share it to any storages that were missing it.
                        let storagesNeedingShare = storages.filter { !areStoragesEqual($0, storage) }
                        await shareResolvedPackages(result, for: originHash, to: storagesNeedingShare)

                        return .restored(result)
                    }
                } catch {
                    logger.warning(
                        "⚠️ Restoring resolved packages from cache storage: \(logSuffix) failed",
                        metadata: .color(.yellow)
                    )
                    errors.append(error)
                    continue
                }
            }

            logger.info("⏹️ Restoration of resolved packages finished", metadata: .color(.green))

            if errors.isEmpty {
                return .noCache
            } else {
                return .failed(CombinedErrors(errors: errors))
            }
        }

        /// Shares resolved packages to storages that don't have them cached yet.
        private func shareResolvedPackages(
            _ resolvedPackages: [ResolvedPackage],
            for originHash: String,
            to storages: [any ResolvedPackagesCacheStorage]
        ) async {
            do {
                try await storages.asyncForEach(numberOfConcurrentTasks: Self.defaultParallelNumber) { storage in
                    if try await !storage.existsValidCache(for: originHash) {
                        logger.info("🔄 Sharing resolved packages to \(storage.displayName)")
                        await self.cacheResolvedPackages(resolvedPackages, for: originHash, to: storage)
                    }
                }
            } catch {
                logger.warning("⚠️ Failed to share resolved packages to cache storages: \(error)", metadata: .color(.yellow))
            }
        }

        /// Attempts to restore resolved packages from a specific cache storage.
        private func restoreCacheIfPossible(for originHash: String, storage: some ResolvedPackagesCacheStorage) async throws -> [ResolvedPackage] {
            guard try await storage.existsValidCache(for: originHash) else {
                logger.info("ℹ️ Cache not found for resolved packages (\(originHash)) from cache storage.", metadata: .color(.green))
                return []
            }

            let restoredPackages = try await storage.fetchResolvedPackages(for: originHash)
            return restoredPackages
        }

        /// Stores resolved packages to a specific cache storage.
        private func cacheResolvedPackages(
            _ resolvedPackages: [ResolvedPackage],
            for originHash: String,
            to storage: some ResolvedPackagesCacheStorage
        ) async {
            do {
                try await storage.cacheResolvedPackages(resolvedPackages, for: originHash)
            } catch {
                logger.warning("⚠️ Can't create resolved package caches for \(originHash) to cache storage: \(storage.displayName)")
                logger.error(error)
            }
        }

        private func areStoragesEqual(_ lhs: any ResolvedPackagesCacheStorage, _ rhs: any ResolvedPackagesCacheStorage) -> Bool {
            // For LocalDiskCacheStorage (value type), use Equatable comparison
            if let lhsLocal = lhs as? LocalDiskCacheStorage,
               let rhsLocal = rhs as? LocalDiskCacheStorage {
                return lhsLocal == rhsLocal
            }

            // For reference types (actors, classes), use ObjectIdentifier comparison
            return ObjectIdentifier(lhs as AnyObject) == ObjectIdentifier(rhs as AnyObject)
        }

        struct CombinedErrors: LocalizedError {
            var errors: [any Error]

            init(errors: [any Error]) {
                self.errors = errors
            }

            var errorDescription: String? {
                errors.compactMap(\.localizedDescription).joined(separator: "\n\n")
            }
        }

        enum RestoreResult {
            case noCache
            case restored([ResolvedPackage])
            case failed(LocalizedError?)
        }
    }
}

extension [Runner.Options.ResolvedPackagesCachePolicy] {
    /// Builds cache storages filtered by the specified actor kind.
    fileprivate func storages(
        for actor: Runner.Options.CacheActorKind,
        packageLocator: some PackageLocator,
        fileSystem: some FileSystem
    ) -> [any ResolvedPackagesCacheStorage] {
        reduce(into: []) { result, cachePolicy in
            if cachePolicy.actors.contains(actor) {
                result.append(cachePolicy.storage.buildStorage(packageLocator: packageLocator, fileSystem: fileSystem))
            }
        }
    }
}
