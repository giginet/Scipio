import Foundation
import PackageGraph
import Basics

protocol Compiler {
    var descriptionPackage: DescriptionPackage { get }

    func createXCFramework(buildProduct: BuildProduct,
                           outputDirectory: URL,
                           overwrite: Bool) async throws
}

extension Compiler {
    func extractDebugSymbolPaths(
        target: ScipioResolvedModule,
        buildConfiguration: BuildConfiguration,
        sdks: Set<SDK>,
        fileSystem: FileSystem = localFileSystem
    ) async throws -> [SDK: [TSCAbsolutePath]] {
        let extractor = DwarfExtractor()

        var result = [SDK: [TSCAbsolutePath]]()

        for sdk in sdks {
            let dsymPath = descriptionPackage.buildDebugSymbolPath(buildConfiguration: buildConfiguration, sdk: sdk, target: target)
            guard fileSystem.exists(dsymPath) else { continue }
            let debugSymbol = DebugSymbol(
                dSYMPath: dsymPath,
                target: target,
                sdk: sdk,
                buildConfiguration: buildConfiguration
            )
            let dumpedDSYMsMaps = try await extractor.dump(dwarfPath: debugSymbol.dwarfPath)
            let bcSymbolMapPaths: [TSCAbsolutePath] = dumpedDSYMsMaps.values.compactMap { uuid in
                let path = descriptionPackage.productsDirectory(
                    buildConfiguration: debugSymbol.buildConfiguration,
                    sdk: debugSymbol.sdk
                )
                    .appending(component: "\(uuid.uuidString).bcsymbolmap")
                guard fileSystem.exists(path) else { return nil }
                return path
            }
            result[sdk] = [debugSymbol.dSYMPath] + bcSymbolMapPaths
        }
        return result
    }
}

extension DescriptionPackage {
    fileprivate func buildDebugSymbolPath(buildConfiguration: BuildConfiguration, sdk: SDK, target: ScipioResolvedModule) -> TSCAbsolutePath {
        productsDirectory(buildConfiguration: buildConfiguration, sdk: sdk)
            .appending(component: "\(target.name).framework.dSYM")
    }
}
