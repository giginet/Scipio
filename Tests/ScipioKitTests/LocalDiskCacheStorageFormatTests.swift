import Foundation
import Testing
@testable import ScipioKit
@testable import ScipioKitCore

struct LocalDiskCacheStorageFormatTests {
    private let fileSystem: LocalFileSystem = .default
    private let originHash = "testoriginhash"

    @Test("A cached graph round-trips through the storage")
    func writtenCacheRoundTrips() async throws {
        let (storage, baseURL) = makeStorage()
        defer { try? fileSystem.removeFileTree(baseURL) }

        let original = [try ResolvedGraphFixtures.diamondChainPackage(depth: 8)]
        try await storage.cacheResolvedPackages(original, for: originHash)
        let fetched = try await storage.fetchResolvedPackages(for: originHash)

        #expect(fetched == original)
        // Deep fidelity, independent of the identity-based `==`.
        let encoder = ResolvedGraphFixtures.makeCanonicalJSONEncoder()
        let originalBytes = try encoder.encode(ResolvedPackagesSnapshot(resolvedPackages: original))
        let fetchedBytes = try encoder.encode(ResolvedPackagesSnapshot(resolvedPackages: fetched))
        #expect(fetchedBytes == originalBytes)
        // The storage must write the canonical bytes the format fixture pins;
        // an encoder configuration drift would silently miss on every old file.
        #expect(try fileSystem.readFileContents(cacheFileURL(in: baseURL)) == originalBytes)
    }

    @Test("A cache file in the legacy format is treated as a miss and deleted")
    func legacyFormatIsTreatedAsMiss() async throws {
        let (storage, baseURL) = makeStorage()
        defer { try? fileSystem.removeFileTree(baseURL) }

        // The legacy format: `[ResolvedPackage]` encoded via its Codable
        // conformance, which is unchanged.
        let legacyData = try JSONEncoder().encode([try ResolvedGraphFixtures.diamondChainPackage(depth: 3)])
        let fileURL = cacheFileURL(in: baseURL)
        try fileSystem.writeFileContents(fileURL, data: legacyData)

        let fetched = try await storage.fetchResolvedPackages(for: originHash)

        #expect(fetched.isEmpty)
        #expect(!fileSystem.exists(fileURL))
    }

    @Test("A cache file with an unsupported format version is treated as a miss and deleted")
    func unsupportedFormatVersionIsTreatedAsMiss() async throws {
        let (storage, baseURL) = makeStorage()
        defer { try? fileSystem.removeFileTree(baseURL) }

        let fileURL = cacheFileURL(in: baseURL)
        let json = #"{"formatVersion": 99, "modules": [], "products": [], "packages": []}"#
        try fileSystem.writeFileContents(fileURL, data: Data(json.utf8))

        let fetched = try await storage.fetchResolvedPackages(for: originHash)

        #expect(fetched.isEmpty)
        #expect(!fileSystem.exists(fileURL))
    }

    @Test("existsValidCache is true only for a restorable cache file")
    func existsValidCacheRequiresRestorability() async throws {
        let (storage, baseURL) = makeStorage()
        defer { try? fileSystem.removeFileTree(baseURL) }
        let fileURL = cacheFileURL(in: baseURL)

        #expect(try await !storage.existsValidCache(for: originHash))

        try await storage.cacheResolvedPackages([try ResolvedGraphFixtures.diamondChainPackage(depth: 3)], for: originHash)
        #expect(try await storage.existsValidCache(for: originHash))
        #expect(fileSystem.exists(fileURL))

        try fileSystem.writeFileContents(fileURL, data: Data("broken".utf8))
        #expect(try await !storage.existsValidCache(for: originHash))
        #expect(!fileSystem.exists(fileURL))
    }

    @Test("I/O errors propagate as failures instead of being treated as misses")
    func ioErrorsPropagate() async throws {
        let baseURL = fileSystem.tempDirectory.appending(components: "LocalDiskCacheStorageFormatTests", UUID().uuidString)
        let storage = PackageResolver.LocalDiskCacheStorage(baseURL: baseURL, fileSystem: FailingReadFileSystem())

        await #expect(throws: FailingReadFileSystem.StubError.self) {
            _ = try await storage.fetchResolvedPackages(for: originHash)
        }
        await #expect(throws: FailingReadFileSystem.StubError.self) {
            _ = try await storage.existsValidCache(for: originHash)
        }
    }

    // MARK: Helpers

    private func makeStorage() -> (storage: PackageResolver.LocalDiskCacheStorage, baseURL: URL) {
        let baseURL = fileSystem.tempDirectory.appending(components: "LocalDiskCacheStorageFormatTests", UUID().uuidString)
        return (PackageResolver.LocalDiskCacheStorage(baseURL: baseURL, fileSystem: fileSystem), baseURL)
    }

    private func cacheFileURL(in baseURL: URL) -> URL {
        baseURL.appending(component: "ResolvedPackages_\(originHash).json")
    }
}

/// A file system whose reads always fail, to simulate genuine I/O errors.
private struct FailingReadFileSystem: FileSystem {
    struct StubError: Error {}

    private let base = LocalFileSystem.default

    var tempDirectory: URL { base.tempDirectory }
    var cachesDirectory: URL? { base.cachesDirectory }
    var currentWorkingDirectory: URL? { base.currentWorkingDirectory }

    func exists(_ path: URL, followSymlink: Bool) -> Bool { true }
    func readFileContents(_ path: URL) throws -> Data { throw StubError() }

    func writeFileContents(_ path: URL, data: Data) throws { try base.writeFileContents(path, data: data) }
    func isDirectory(_ path: URL) -> Bool { base.isDirectory(path) }
    func isFile(_ path: URL) -> Bool { base.isFile(path) }
    func isSymlink(_ path: URL) -> Bool { base.isSymlink(path) }
    func copy(from fromURL: URL, to toURL: URL) throws { try base.copy(from: fromURL, to: toURL) }
    func createDirectory(_ directoryPath: URL, recursive: Bool) throws { try base.createDirectory(directoryPath, recursive: recursive) }
    func move(from fromURL: URL, to toURL: URL) throws { try base.move(from: fromURL, to: toURL) }
    func getDirectoryContents(_ directoryPath: URL) throws -> [String] { try base.getDirectoryContents(directoryPath) }
    func removeFileTree(_ path: URL) throws { try base.removeFileTree(path) }
}
