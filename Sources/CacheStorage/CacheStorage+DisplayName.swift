public extension FrameworkCacheStorage {
    /// The display name of the cache storage used for logging purpose
    var displayName: String {
        // TODO: Define the property as FrameworkCacheStorage's requirement
        "\(type(of: self))"
    }
}

public extension ResolvedPackagesCacheStorage {
    /// The display name of the cache storage used for logging purpose
    var displayName: String {
        // TODO: Define the property as ResolvedPackagesCacheStorage's requirement
        "\(type(of: self))"
    }
}
