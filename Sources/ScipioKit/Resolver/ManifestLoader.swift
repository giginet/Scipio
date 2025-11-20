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

        let manifest = try jsonDecoder.decode(Manifest.self, from: manifestData)
        return manifest
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
