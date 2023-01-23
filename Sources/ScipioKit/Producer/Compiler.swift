import Foundation
import PackageGraph
import TSCBasic

protocol Compiler {
    var rootPackage: Package { get }

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
    ) async throws -> [URL] {
        let extractor = DwarfExtractor()

        let debugSymbols: [DebugSymbol] = sdks.compactMap { sdk in
            let dsymPath = rootPackage.buildDebugSymbolPath(buildConfiguration: buildConfiguration, sdk: sdk, target: target)
            guard fileSystem.exists(dsymPath) else { return nil }
            return DebugSymbol(dSYMPath: dsymPath,
                               target: target,
                               sdk: sdk,
                               buildConfiguration: buildConfiguration)
        }
        // You can use AsyncStream
        var symbolMapPaths: [URL] = []
        for dSYMs in debugSymbols {
            let dumpedDSYMsMaps = try await extractor.dump(dwarfPath: dSYMs.dwarfPath)
            let paths = dumpedDSYMsMaps.values.map { uuid in
                rootPackage.buildArtifactsDirectoryPath(buildConfiguration: dSYMs.buildConfiguration, sdk: dSYMs.sdk)
                    .appendingPathComponent("\(uuid.uuidString).bcsymbolmap")
            }
            symbolMapPaths.append(contentsOf: paths)
        }
        return debugSymbols.map { $0.dSYMPath } + symbolMapPaths
    }
}

extension Package {
    fileprivate func buildArtifactsDirectoryPath(buildConfiguration: BuildConfiguration, sdk: SDK) -> URL {
        workspaceDirectory.appendingPathComponent("\(buildConfiguration.settingsValue)-\(sdk.settingValue)")
    }

    fileprivate func buildDebugSymbolPath(buildConfiguration: BuildConfiguration, sdk: SDK, target: ResolvedTarget) -> URL {
        buildArtifactsDirectoryPath(buildConfiguration: buildConfiguration, sdk: sdk).appendingPathComponent("\(target).framework.dSYM")
    }
}
