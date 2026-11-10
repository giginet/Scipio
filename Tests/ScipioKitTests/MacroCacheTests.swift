import CacheStorage
import Foundation
import Testing
@testable import ScipioKit

struct MacroCacheTests {
    private func key(revision: String = "123", swiftVersion: String = "Swift 6", schemaVersion: Int = 1) -> MacroCacheKey {
        MacroCacheKey(
            schemaVersion: schemaVersion, artifactKind: .macroPlugin, targetName: "ExamplePlugin",
            dependencies: [
                .init(
                    packageIdentity: "example",
                    pin: .sourceControl(revision: revision),
                    targetName: "ExamplePlugin"
                ),
            ],
            swiftVersion: swiftVersion, clangVersion: "Clang", xcodeVersion: "Xcode",
            hostArchitecture: "arm64", deploymentTarget: nil, rootMacOSPlatform: nil, configuration: "debug",
            scipioVersion: "Scipio"
        )
    }

    @Test func macroKeyIncludesSourceAndToolchain() throws {
        let original = key()
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(MacroCacheKey.self, from: data) == original)
        #expect(try original.calculateChecksum() != key(revision: "456").calculateChecksum())
        #expect(try original.calculateChecksum() != key(swiftVersion: "Swift 7").calculateChecksum())
    }

    @Test func localMacroArtifactRoundTripPreservesExecutable() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let source = root.appending(path: "source")
        let destination = root.appending(path: "restored")
        try manager.createDirectory(at: source, withIntermediateDirectories: true)
        let executable = source.appending(path: "ExamplePlugin")
        try Data("plugin".utf8).write(to: executable)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let storage = LocalDiskCacheStorage(baseURL: root)
        let key = key()

        #expect(try await !storage.existsArtifact(for: key, kind: .macroPlugin))
        try await storage.cacheArtifact(source, for: key, kind: .macroPlugin)
        #expect(try await storage.existsArtifact(for: key, kind: .macroPlugin))
        try await storage.fetchArtifact(for: key, kind: .macroPlugin, to: destination)
        let restored = destination.appending(path: "ExamplePlugin")
        #expect(try Data(contentsOf: restored) == Data("plugin".utf8))
        #expect(manager.isExecutableFile(atPath: restored.path))
        let cachePath = try root.appending(
            components: "Scipio", "Macros", "ExamplePlugin", key.calculateChecksum(), "ExamplePlugin", "ExamplePlugin"
        )
        #expect(manager.fileExists(atPath: cachePath.path))
    }

    @Test func versionDecoderRejectsUnknownSchema() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONEncoder().encode(key()).write(to: url)
        #expect(try MacroVersionFileDecoder().decode(versionFile: url) == key())
        try JSONEncoder().encode(key(schemaVersion: 99)).write(to: url)
        #expect(throws: MacroVersionFileDecoder.Error.self) {
            try MacroVersionFileDecoder().decode(versionFile: url)
        }
    }
}
