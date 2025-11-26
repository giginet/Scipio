import Foundation
import CacheStorage

/// The pseudo cache storage for "project cache policy", which treats built frameworks under the project's output directory (e.g. `XCFrameworks`)
/// as valid caches but does not saving / restoring anything.
struct ProjectCacheStorage: FrameworkCacheStorage {
    func existsValidCache(for cacheKey: some CacheKey) async throws -> Bool { false }
    func fetchArtifacts(for cacheKey: some CacheKey, to destinationDir: URL) async throws {}
    func cacheFramework(_ frameworkPath: URL, for cacheKey: some CacheKey) async throws {}
}
