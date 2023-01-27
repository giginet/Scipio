import Foundation
import PackageGraph
import PackageModel

struct BinaryExtractor {
    var package: Package
    var outputDirectory: URL
    var fileSystem: any FileSystem

    @discardableResult
    func extract(of binaryTarget: BinaryTarget, overwrite: Bool) throws -> URL {
        let sourcePath = binaryTarget.artifactPath
        let frameworkName = "\(binaryTarget.c99name).xcframework"
        let fileName = sourcePath.basename
        let destinationPath = outputDirectory.appendingPathComponent(fileName)
        if fileSystem.exists(destinationPath) && overwrite {
            logger.info("💥 Delete \(frameworkName)", metadata: .color(.red))
            try fileSystem.removeFileTree(at: destinationPath)
        }
        try fileSystem.copy(from: sourcePath.asURL, to: destinationPath)

        return destinationPath
    }
}
