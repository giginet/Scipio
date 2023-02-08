import Foundation
import PackageGraph
import TSCBasic

protocol Compiler {
    var descriptionPackage: DescriptionPackage { get }

    func createXCFramework(buildProduct: BuildProduct,
                           outputDirectory: URL,
                           overwrite: Bool) async throws
}

extension Compiler {
    func extractDebugSymbolPaths(
        target: ResolvedTarget,
        buildConfiguration: BuildConfiguration,
        sdks: Set<SDK>,
        fileSystem: FileSystem = localFileSystem
    ) async throws -> [AbsolutePath] {
        let extractor = DwarfExtractor()

        let debugSymbols: [DebugSymbol] = sdks.compactMap { sdk in
            let dsymPath = descriptionPackage.buildDebugSymbolPath(buildConfiguration: buildConfiguration, sdk: sdk, target: target)
            guard fileSystem.exists(dsymPath) else { return nil }
            return DebugSymbol(dSYMPath: dsymPath,
                               target: target,
                               sdk: sdk,
                               buildConfiguration: buildConfiguration)
        }
        // You can use AsyncStream
        var symbolMapPaths: [AbsolutePath] = []
        for dSYMs in debugSymbols {
            let dumpedDSYMsMaps = try await extractor.dump(dwarfPath: dSYMs.dwarfPath)
            let paths = dumpedDSYMsMaps.values.map { uuid in
                descriptionPackage.buildArtifactsDirectoryPath(buildConfiguration: dSYMs.buildConfiguration, sdk: dSYMs.sdk)
                    .appending(component: "\(uuid.uuidString).bcsymbolmap")
            }
            symbolMapPaths.append(contentsOf: paths)
        }
        return debugSymbols.map { $0.dSYMPath } + symbolMapPaths
    }
}

extension DescriptionPackage {
    fileprivate func buildArtifactsDirectoryPath(buildConfiguration: BuildConfiguration, sdk: SDK) -> AbsolutePath {
        workspaceDirectory.appending(component: "\(buildConfiguration.settingsValue)-\(sdk.settingValue)")
    }

    fileprivate func buildDebugSymbolPath(buildConfiguration: BuildConfiguration, sdk: SDK, target: ResolvedTarget) -> AbsolutePath {
        buildArtifactsDirectoryPath(buildConfiguration: buildConfiguration, sdk: sdk).appending(component: "\(target).framework.dSYM")
    }
}
