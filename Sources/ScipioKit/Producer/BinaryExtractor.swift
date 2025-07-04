import Foundation

struct BinaryExtractor {
    var descriptionPackage: DescriptionPackage
    var outputDirectory: URL
    var fileSystem: any FileSystem

    @discardableResult
    func extract(of binaryTarget: ResolvedModule, overwrite: Bool) throws -> URL {
        guard case let .binary(binaryLocation) = binaryTarget.resolvedModuleType else {
            preconditionFailure(
                """
                \(#function) must be called with a binary target.
                target name: \(binaryTarget.c99name), actual module type: \(binaryTarget.resolvedModuleType)
                """
            )
        }

        let artifactURL = binaryLocation.artifactURL(rootPackageDirectory: descriptionPackage.packageDirectory)

        let frameworkName = "\(binaryTarget.c99name).xcframework"
        let fileName = artifactURL.lastPathComponent
        let destinationPath = outputDirectory.appendingPathComponent(fileName)
        if fileSystem.exists(destinationPath) && overwrite {
            logger.info("🗑️ Delete \(frameworkName)", metadata: .color(.red))
            try fileSystem.removeFileTree(destinationPath)
        }
        try fileSystem.copy(
            from: artifactURL,
            to: destinationPath
        )

        return destinationPath
    }
}
