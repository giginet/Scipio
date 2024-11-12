import Foundation
import ScipioStorage

/// The pseudo cache storage for "project cache policy", which treats built frameworks under the project's output directory (e.g. `XCFrameworks`)
/// as valid caches but does not saving / restoring anything.
public struct ProjectCacheStorage: CacheStorage {
    public func existsValidCache(for cacheKey: some ScipioStorage.CacheKey) async throws -> Bool { false }
    public func fetchArtifacts(for cacheKey: some ScipioStorage.CacheKey, to destinationDir: URL) async throws {}
    public func cacheFramework(_ frameworkPath: URL, for cacheKey: some ScipioStorage.CacheKey) async throws {}
}
