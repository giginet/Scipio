import Foundation
import PackageGraph
import PackageModel

struct BinaryExtractor {
    var package: Package
    var outputDirectory: URL
    var fileSystem: any FileSystem

    func extract(of binaryTarget: BinaryTarget) throws -> URL {
        try fileSystem.copy(from: binaryTarget.artifactPath.asURL, to: outputDirectory)

        let fileName = binaryTarget.artifactPath.basename

        return outputDirectory.appendingPathComponent(fileName)
    }
}
