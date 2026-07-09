import Foundation
import PackageManifestKit
import ScipioKitCore

/// Loads the `Manifest` of a Swift package
struct ManifestLoader: @unchecked Sendable {
    private let executor: any Executor
    private let jsonDecoder = JSONDecoder()

    init(executor: some Executor) {
        self.executor = executor
    }

    /// Loads the manifest for a package at a local path.
    /// - Parameter packagePath: The file path of the package.
    /// - Returns: A decoded `Manifest` object.
    func loadManifest(for packagePath: URL) async throws -> Manifest {
        try await loadManifest(path: packagePath.path(percentEncoded: false))
    }

    /// Loads the manifest for a dependency package.
    /// - Parameter dependencyPackage: A package from the dependencies.
    /// - Returns: A decoded `Manifest` object.
    @_disfavoredOverload
    func loadManifest(for dependencyPackage: DependencyPackage) async throws -> Manifest {
        try await loadManifest(path: dependencyPackage.path)
    }

    private func loadManifest(path: String) async throws -> Manifest {
        let commands = [
            "/usr/bin/xcrun",
            "swift",
            "package",
            "dump-package",
            "--package-path",
            path,
        ]

        let manifestData = try await executor.execute(commands)
            .unwrapOutput()
            .data(using: .utf8)

        guard let manifestData else {
            throw Error.utf8EncodingFailed
        }

        return try decodeManifest(from: manifestData)
    }

    // PackageManifestKit 0.2.0 expects Manifest.traits as [String]?, but SwiftPM 6.1+
    // dump-package emits trait objects. Since Scipio does not read top-level traits,
    // decode directly and, only on failure, drop the field and retry. Remove once
    // PackageManifestKit models Manifest.traits as [TraitDescription]?.
    private func decodeManifest(from data: Data) throws -> Manifest {
        do {
            return try jsonDecoder.decode(Manifest.self, from: data)
        } catch {
            guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["traits"] != nil else {
                throw error
            }
            object["traits"] = nil
            return try jsonDecoder.decode(Manifest.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }

    enum Error: LocalizedError {
        case utf8EncodingFailed

        var errorDescription: String? {
            switch self {
            case .utf8EncodingFailed:
                "Failed to convert the command output string to UTF-8 encoded data"
            }
        }
    }
}
