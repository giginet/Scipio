import Foundation
import CacheStorage
import PackageManifestKit

extension FrameworkProducer {
    /// Sendable interface to provide restore caches
    struct Restorer: Sendable {
        let outputDir: URL
        let fileSystem: any FileSystem

        // Return true if pre-built artifact is available (already existing or restored from cache)
        func restore(
            target: CacheSystem.CacheTarget,
            cacheKey: SwiftPMCacheKey?,
            cacheSystem: CacheSystem,
            cacheStorage: any FrameworkCacheStorage
        ) async throws -> Bool {
            let product = target.buildProduct
            let frameworkName = product.frameworkName

            guard let expectedCacheKey = cacheKey else {
                return false
            }
            let expectedCacheKeyHash = try expectedCacheKey.calculateChecksum()

            let restoreResult = await cacheSystem.restoreCacheIfPossible(cacheKey: expectedCacheKey, storage: cacheStorage)
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
