import Foundation
import ScipioKit

public struct S3StorageConfig {
    public var bucket: String
    public var region: String
    public var endpoint: URL
    public var authenticationMode: AuthenticationMode
    public var shouldPublishObject: Bool

    public init(
        authenticationMode: AuthenticationMode,
        bucket: String,
        region: String,
        endpoint: URL,
        shouldPublishObject: Bool = false
    ) {
        self.authenticationMode = authenticationMode
        self.bucket = bucket
        self.region = region
        self.endpoint = endpoint
        self.shouldPublishObject = shouldPublishObject
    }

    public enum AuthenticationMode {
        case usePublicURL
        case authorized(accessKeyID: String, secretAccessKey: String)
    }

    fileprivate var objectStorageClientType: any ObjectStorageClient.Type {
        switch authenticationMode {
        case .usePublicURL:
            return PublicURLObjectStorageClient.self
        case .authorized:
            return APIObjectStorageClient.self
        }
    }
}

public struct S3Storage: CacheStorage {
    private let storagePrefix: String?
    private let storageClient: any ObjectStorageClient
    private let archiver: AARArchiver

    public init(config: S3StorageConfig, storagePrefix: String? = nil) throws {
        self.storageClient = try config.objectStorageClientType.init(storageConfig: config)
        self.storagePrefix = storagePrefix
        self.archiver = try AARArchiver()
    }

    public func existsValidCache(for cacheKey: ScipioKit.CacheKey) async throws -> Bool {
        let objectStorageKey = try constructObjectStorageKey(from: cacheKey)
        do {
            return try await storageClient.isExistObject(at: objectStorageKey)
        } catch {
            throw error
        }
    }

    public func fetchArtifacts(for cacheKey: ScipioKit.CacheKey, to destinationDir: URL) async throws {
        let objectStorageKey = try constructObjectStorageKey(from: cacheKey)
        let archiveData = try await storageClient.fetchObject(at: objectStorageKey)
        let destinationPath = destinationDir.appendingPathComponent(cacheKey.frameworkName)
        try archiver.extract(archiveData, to: destinationPath)
    }

    public func cacheFramework(_ frameworkPath: URL, for cacheKey: ScipioKit.CacheKey) async throws {
        let data = try archiver.compress(frameworkPath)
        let objectStorageKey = try constructObjectStorageKey(from: cacheKey)
        try await storageClient.putObject(data, at: objectStorageKey)
    }

    private func constructObjectStorageKey(from cacheKey: CacheKey) throws -> String {
        let frameworkName = cacheKey.targetName
        let checksum = try cacheKey.calculateChecksum()
        let archiveName = "\(checksum).aar"
        return [storagePrefix, frameworkName, archiveName]
            .compactMap { $0 }
            .joined(separator: "/")
    }
}
