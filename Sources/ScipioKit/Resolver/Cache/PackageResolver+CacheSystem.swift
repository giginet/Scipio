import Foundation
import AsyncOperations
import ScipioKitCore
import CacheStorage

extension PackageResolver {
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

        func cacheResolvedPackages(
            _ resolvedPackages: [ResolvedPackage],
            for originHash: String
        ) async {
            let storages = cachePolicies.storages(for: .producer, packageLocator: packageLocator, fileSystem: fileSystem)
            guard !storages.isEmpty else { return }

            logger.info(
                "🚀 Caching resolved packages to \(storages.count) cache storage(s)",
                metadata: .color(.green)
            )

            await storages.asyncForEach(numberOfConcurrentTasks: Self.defaultParallelNumber) { storage in
                await self.cacheResolvedPackages(resolvedPackages, for: originHash, to: storage)
            }
        }

        func restoreCacheIfPossible(for originHash: String) async -> RestoreResult {
            let storages = cachePolicies.storages(for: .consumer, packageLocator: packageLocator, fileSystem: fileSystem)
            guard !storages.isEmpty else {
                return .noCache
            }

            logger.info(
                "▶️ Starting restoration of resolved packages from \(storages.count) cache storage(s)",
                metadata: .color(.green)
            )

            var errors: [any Error] = []
            var storagesNeedingShare: [any ResolvedPackagesCacheStorage] = []

            for (index, storage) in storages.enumerated() {
                let storageName = storage.displayName
                let logSuffix = "[\(index)] \(storageName)"

                if index == storages.startIndex {
                    logger.info(
                        "▶️ Starting restoration with cache storage: \(logSuffix)",
                        metadata: .color(.green)
                    )
                } else {
                    logger.info(
                        "⏭️ Falling back to next cache storage: \(logSuffix)",
                        metadata: .color(.green)
                    )
                }

                do {
                    let result = try await restoreCacheIfPossible(for: originHash, storage: storage)
                    if result.isEmpty {
                        logger.info("ℹ️ Cache not found for resolved packages from cache storage: \(logSuffix)", metadata: .color(.green))
                        // No valid cache here
                        // remember to share later if we find one.
                        storagesNeedingShare.append(storage)
                        continue
                    } else {
                        logger.info(
                            "✅ Restored resolved packages from cache storage: \(logSuffix)",
                            metadata: .color(.green)
                        )
                        // Found a cache. Share it to any storages that were missing it.
                        if !storagesNeedingShare.isEmpty {
                            await shareResolvedPackages(result, for: originHash, to: storagesNeedingShare)
                        }
                        logger.info("⏹️ Restoration finished", metadata: .color(.green))
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

            logger.info("⏹️ Restoration finished", metadata: .color(.green))

            if errors.isEmpty {
                return .noCache
            } else {
                return .failed(CombinedErrors(errors: errors))
            }
        }

        private func shareResolvedPackages(
            _ resolvedPackages: [ResolvedPackage],
            for originHash: String,
            to storages: [any ResolvedPackagesCacheStorage]
        ) async {
            logger.info(
                "🔄 Sharing resolved packages to \(storages.count) other cache storage(s)",
                metadata: .color(.blue)
            )

            await storages.asyncForEach(numberOfConcurrentTasks: Self.defaultParallelNumber) { storage in
                await self.cacheResolvedPackages(resolvedPackages, for: originHash, to: storage)
            }

            logger.info("⏹️ Sharing to other cache storages finished", metadata: .color(.green))
        }

        private func restoreCacheIfPossible(for originHash: String, storage: some ResolvedPackagesCacheStorage) async throws -> [ResolvedPackage] {
            guard try await storage.existsValidCache(for: originHash) else {
                return []
            }

            let restoredPackages = try await storage.fetchResolvedPackages(for: originHash)
            return restoredPackages
        }

        private func cacheResolvedPackages(
            _ resolvedPackages: [ResolvedPackage],
            for originHash: String,
            to storage: some ResolvedPackagesCacheStorage
        ) async {
            do {
                logger.info(
                    "🚀 Cache resolved packages to cache storage: \(storage.displayName)",
                    metadata: .color(.green)
                )
                try await storage.cacheResolvedPackages(resolvedPackages, for: originHash)
            } catch {
                logger.warning("⚠️ Can't create resolved package caches for \(originHash) to cache storage: \(storage.displayName)")
            }
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
