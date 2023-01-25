import Foundation
import PackageGraph
import PackageModel
import TSCBasic

struct BinaryExtractor {
    var package: Package
    var outputDirectory: URL
    var fileSystem: any FileSystem

    @discardableResult
    func extract(of binaryTarget: BinaryTarget) throws -> URL {

        let sourcePath = binaryTarget.artifactPath
        let fileName = sourcePath.basename
        let destinationPath = outputDirectory.appendingPathComponent(fileName)
        if !fileSystem.exists(destinationPath.absolutePath) {
            try fileSystem.copy(from: sourcePath, to: destinationPath.absolutePath)
        }

        return destinationPath
    }
}
