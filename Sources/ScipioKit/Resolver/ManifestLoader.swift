import Foundation
import PackageManifestKit

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
        let manifestString = try await executor.execute(commands).unwrapOutput()
        let manifest = try jsonDecoder.decode(Manifest.self, from: manifestString)
        return manifest
    }
}
