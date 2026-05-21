import Foundation
@testable import ScipioKit
import Testing

struct CacheStorageDisplayNameTests {
    @Test
    func frameworkLocalDiskCacheStorageDisplayNameIncludesCustomBaseURL() {
        let baseURL = URL(filePath: "/tmp/scipio-framework-cache")
        let storage = LocalDiskCacheStorage(baseURL: baseURL)
        let displayName = storage.displayName

        #expect(displayName.contains("LocalDiskCacheStorage"))
        #expect(displayName.contains("baseURL"))
        #expect(displayName.contains("cacheURL"))
        #expect(displayName.contains(baseURL.path(percentEncoded: false)))
        #expect(displayName.contains(baseURL.appending(component: "Scipio").path(percentEncoded: false)))
    }

    @Test
    func frameworkLocalDiskCacheStorageDisplayNameIncludesSystemCacheURL() {
        let storage = LocalDiskCacheStorage(baseURL: nil)
        let displayName = storage.displayName

        #expect(displayName.contains("LocalDiskCacheStorage"))
        #expect(displayName.contains("systemCacheURL"))
        #expect(displayName.contains("Scipio"))
    }

    @Test
    func resolvedPackagesLocalDiskCacheStorageDisplayNameIncludesCustomBaseURL() {
        let baseURL = URL(filePath: "/tmp/scipio-resolved-packages-cache")
        let storage = PackageResolver.LocalDiskCacheStorage(baseURL: baseURL)
        let displayName = storage.displayName

        #expect(displayName.contains("LocalDiskCacheStorage"))
        #expect(displayName.contains("baseURL"))
        #expect(displayName.contains("cacheURL"))
        #expect(displayName.contains(baseURL.path(percentEncoded: false)))
    }

    @Test
    func resolvedPackagesLocalDiskCacheStorageDisplayNameIncludesSystemCacheURL() {
        let storage = PackageResolver.LocalDiskCacheStorage(baseURL: nil)
        let displayName = storage.displayName

        #expect(displayName.contains("LocalDiskCacheStorage"))
        #expect(displayName.contains("systemCacheURL"))
        #expect(displayName.contains("Scipio"))
        #expect(displayName.contains("ResolvedPackages"))
    }
}
