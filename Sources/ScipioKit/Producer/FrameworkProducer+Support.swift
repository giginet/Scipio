import Foundation
import CacheStorage
import OrderedCollections
import PackageManifestKit

extension FrameworkProducer {
    enum Restorer {
        static func restore(
            target: CacheSystem.CacheTarget,
            cacheKey: SwiftPMCacheKey?,
            cacheSystem: CacheSystem,
            cacheStorage: any FrameworkCacheStorage,
            logCacheMiss: Bool = true
        ) async throws -> Bool {
            let product = target.buildProduct
            let frameworkName = product.frameworkName

            guard let expectedCacheKey = cacheKey else {
                return false
            }
            let restoreResult = await cacheSystem.restoreCacheIfPossible(cacheKey: expectedCacheKey, storage: cacheStorage)
            if case .noCache = restoreResult, !logCacheMiss {
                return false
            }
            let expectedCacheKeyHash = try expectedCacheKey.calculateChecksum()
            switch restoreResult {
            case .succeeded:
                logger.info("✅ Restore \(frameworkName) (\(expectedCacheKeyHash)) from cache storage.", metadata: .color(.green))
                return true
            case .failed(let error):
                logger.warning("⚠️ Restoring \(frameworkName) (\(expectedCacheKeyHash)) is failed", metadata: .color(.yellow))
                if let description = error?.errorDescription {
                    logger.warning("\(description)", metadata: .color(.yellow))
                }
                return false
            case .noCache:
                logger.info("ℹ️ Cache not found for \(frameworkName) (\(expectedCacheKeyHash)) from cache storage.", metadata: .color(.green))
                return false
            }
        }
    }

    struct TargetBuildResult {
        var builtTargets: OrderedSet<CacheSystem.CacheTarget> = []
        var restoredSetsToSourceStorage: [Set<CacheSystem.CacheTarget>: any FrameworkCacheStorage] = [:]
        var error: (any Swift.Error)?
    }

    struct MacroCacheInputs {
        let checksumsByTarget: [String: [DependencyCacheKeyChecksum]]
        let uncacheableTargets: Set<String>
        let uncacheableTargetsIncludingDependents: Set<String>
    }

    static func areStoragesEqual(_ lhs: any FrameworkCacheStorage, _ rhs: any FrameworkCacheStorage) -> Bool {
        // ProjectCacheStorage instances are always considered the same
        if lhs is ProjectCacheStorage && rhs is ProjectCacheStorage {
            return true
        }

        // For LocalDiskCacheStorage (value type), use Equatable comparison
        if let lhsLocal = lhs as? LocalDiskCacheStorage,
           let rhsLocal = rhs as? LocalDiskCacheStorage {
            return lhsLocal == rhsLocal
        }

        // For reference types (actors, classes), use ObjectIdentifier comparison
        return ObjectIdentifier(lhs as AnyObject) == ObjectIdentifier(rhs as AnyObject)
    }

    enum Error: LocalizedError {
        case unsupportedTargetType(targetName: String, type: Target.TargetKind)

        var errorDescription: String? {
            switch self {
            case .unsupportedTargetType(let targetName, let type):
                return "Cannot produce an XCFramework for \(targetName): unsupported target type \(type.rawValue)"
            }
        }
    }

}
