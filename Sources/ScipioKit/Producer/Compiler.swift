import Foundation
import PIFKit
import TSCBasic

protocol Compiler {
    var descriptionPackage: DescriptionPackage { get }

    func createXCFramework(buildProduct: BuildProduct,
                           outputDirectory: URL,
                           overwrite: Bool) async throws
}

extension Compiler {
    func extractDebugSymbolPaths(
        target: ResolvedModule,
        buildConfiguration: BuildConfiguration,
        sdks: Set<SDK>,
        fileSystem: FileSystem = localFileSystem
    ) async throws -> [SDK: [TSCAbsolutePath]] {
        let extractor = DwarfExtractor()

        var result = [SDK: [TSCAbsolutePath]]()

        for sdk in sdks {
            let dsymPath = descriptionPackage.buildDebugSymbolPath(
                buildConfiguration: buildConfiguration,
                sdk: sdk,
                target: target
            )
            guard fileSystem.exists(dsymPath) else { continue }

            let dwarfPath = extractor.dwarfPath(for: target, dSYMPath: dsymPath)
            let dumpedDSYMsMaps = try await extractor.dump(dwarfPath: dwarfPath)
            let bcSymbolMapPaths: [TSCAbsolutePath] = dumpedDSYMsMaps.values.compactMap { uuid in
                let path = descriptionPackage.productsDirectory(
                    buildConfiguration: buildConfiguration,
                    sdk: sdk
                )
                    .appending(component: "\(uuid.uuidString).bcsymbolmap")
                guard fileSystem.exists(path) else { return nil }
                return path
            }
            result[sdk] = [dsymPath] + bcSymbolMapPaths
        }
        return result
    }
}

extension DescriptionPackage {
    fileprivate func buildDebugSymbolPath(
        buildConfiguration: BuildConfiguration,
        sdk: SDK,
        target: ResolvedModule
    ) -> TSCAbsolutePath {
        productsDirectory(buildConfiguration: buildConfiguration, sdk: sdk)
            .appending(component: "\(target.name).framework.dSYM")
    }
}
