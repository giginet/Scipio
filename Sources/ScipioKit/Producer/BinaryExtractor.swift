import Foundation
import PackageGraph
import PackageModel
import TSCBasic

struct BinaryExtractor {
    var package: DescriptionPackage
    var outputDirectory: URL
    var fileSystem: any FileSystem

    @discardableResult
    func extract(of binaryTarget: ScipioBinaryModule, overwrite: Bool) throws -> URL {
        let sourcePath = binaryTarget.artifactPath
        let frameworkName = "\(binaryTarget.c99name).xcframework"
        let fileName = sourcePath.basename
        let destinationPath = outputDirectory.appendingPathComponent(fileName)
        if fileSystem.exists(destinationPath.absolutePath) && overwrite {
            logger.info("🗑️ Delete \(frameworkName)", metadata: .color(.red))
            try fileSystem.removeFileTree(destinationPath.absolutePath)
        }
        try fileSystem.copy(
            from: sourcePath,
            to: destinationPath.absolutePath.spmAbsolutePath
        )

        return destinationPath
    }
}
