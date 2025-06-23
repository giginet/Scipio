import Foundation
import TSCBasic

struct BinaryExtractor {
    var descriptionPackage: DescriptionPackage
    var outputDirectory: URL
    var fileSystem: any FileSystem

    @discardableResult
    func extract(of binaryTarget: ResolvedModule, overwrite: Bool) async throws -> URL {
        guard case let .binary(binaryLocation) = binaryTarget.resolvedModuleType else {
            preconditionFailure(
                """
                \(#function) must be called with a binary target.
                target name: \(binaryTarget.c99name), actual module type: \(binaryTarget.resolvedModuleType)
                """
            )
        }

        let artifactURL = binaryLocation.artifactURL(rootPackageDirectory: descriptionPackage.packageDirectory.asURL)

        let frameworkName = "\(binaryTarget.c99name).xcframework"
        let fileName = artifactURL.absolutePath.basename
        let destinationPath = outputDirectory.appendingPathComponent(fileName)
        if await fileSystem.exists(destinationPath) && overwrite {
            logger.info("🗑️ Delete \(frameworkName)", metadata: .color(.red))
            try await fileSystem.removeFileTree(destinationPath)
        }
        try await fileSystem.copy(
            from: artifactURL,
            to: destinationPath
        )

        return destinationPath
    }
}
