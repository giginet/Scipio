import Foundation
import ScipioKitCore
import CryptoKit

private let jsonEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
}()

public protocol FrameworkCacheStorage: Sendable {
    /// The display name of the cache storage used for logging purpose
    var displayName: String { get }

    func existsValidCache(for cacheKey: some CacheKey) async throws -> Bool
    func fetchArtifacts(for cacheKey: some CacheKey, to destinationDir: URL) async throws
    func cacheFramework(_ frameworkPath: URL, for cacheKey: some CacheKey) async throws
    var parallelNumber: Int? { get }
}

@available(*, deprecated, renamed: "FrameworkCacheStorage")
public typealias CacheStorage = FrameworkCacheStorage

public protocol ResolvedPackagesCacheStorage: Sendable {
    /// The display name of the cache storage used for logging purpose
    var displayName: String { get }

    func existsValidCache(for originHash: String) async throws -> Bool
    func fetchResolvedPackages(for originHash: String) async throws -> [ResolvedPackage]
    func cacheResolvedPackages(_ resolvedPackages: [ResolvedPackage], for originHash: String) async throws
}

public protocol CacheKey: Hashable, Codable, Equatable, Sendable {
    var targetName: String { get }
}

extension CacheKey {
    public var frameworkName: String {
        "\(targetName.packageNamed()).xcframework"
    }
}

extension CacheKey {
    public func calculateChecksum() throws -> String {
        let data = try jsonEncoder.encode(self)
        return SHA256.hash(data: data)
            .map { String(format: "%02hhx", $0) }
            .joined()
    }
}

extension FrameworkCacheStorage {
    public var displayName: String {
        "\(type(of: self))"
    }

    public var parallelNumber: Int? {
        nil
    }
}

extension ResolvedPackagesCacheStorage {
    public var displayName: String {
        "\(type(of: self))"
    }
}
