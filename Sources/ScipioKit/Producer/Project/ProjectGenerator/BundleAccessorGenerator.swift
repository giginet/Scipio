import Foundation
import TSCBasic

struct BundleAccessorGenerator {
    private let package: Package
    private let fileSystem: any FileSystem

    init(package: Package, fileSystem: any FileSystem = localFileSystem) {
        self.package = package
        self.fileSystem = fileSystem
    }

    func generate(resourceBundleName: String) throws -> URL {
        let content = generateAccessorContents(resourceBundleName: resourceBundleName)
        let outputPath = package.buildDirectory.appendingPathComponent("\(resourceBundleName)Accessor-generated.swift")
        try fileSystem.writeFileContents(outputPath.absolutePath, data: content)
        return outputPath
    }

    private func generateAccessorContents(resourceBundleName: String) -> Data {
"""
import Foundation

private class BundleMarker { }

extension Foundation.Bundle {
    static let module: Bundle = {
        let frameworkBundle: Bundle = .init(for: BundleMarker.self)
        guard let resourceBundleURL = frameworkBundle.url(forResource: "\(resourceBundleName.asSwiftStringLiteralConstant)", withExtension: "bundle"),
          let bundle = Bundle(url: resourceBundleURL) else {
            fatalError("could not load resource bundle")
        }
        return bundle
    }()
}
""".data(using: .utf8)!
    }
}

extension String {
    fileprivate var asSwiftStringLiteralConstant: String {
        return unicodeScalars.reduce("", { $0 + $1.escaped(asASCII: false) })
    }
}
