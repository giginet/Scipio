import CacheStorage

extension FrameworkCacheStorage {
    /// The display name of the cache storage used for logging purpose
    var displayName: String {
        // TODO: Define the property as FrameworkCacheStorage's requirement in scipio-cache-storage
        "\(type(of: self))"
    }
}
