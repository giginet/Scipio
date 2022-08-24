import Foundation
import TSCUtility
import PackageGraph
import TSCBasic

struct ProjectCacheStrategy: CacheStrategy {
    private let outputDirectory: AbsolutePath
    private let fileSystem: any FileSystem

    init(outputDirectory: AbsolutePath, fileSystem: any FileSystem = localFileSystem) {
        self.outputDirectory = outputDirectory
        self.fileSystem = fileSystem
    }

    func existsValidCache(for cacheKey: CacheKey) async -> Bool {
        let versionFilePath = versionFilePath(for: cacheKey.targetName)
        guard fileSystem.exists(versionFilePath) else { return false }
        let decoder = JSONDecoder()
        do {
            let versionFileKey = try decoder.decode(path: versionFilePath, fileSystem: fileSystem, as: CacheKey.self)
            return versionFileKey == cacheKey
        } catch {
            return false
        }
    }

    func fetchArtifacts(for cacheKey: CacheKey, to destination: AbsolutePath) async throws {
        guard outputDirectory != destination else {
            return
        }
        let versionFileName = versionFileName(for: cacheKey.targetName)
        try fileSystem.move(from: versionFilePath(for: cacheKey.targetName),
                            to: destination.appending(component: versionFileName))
    }

    func cacheFramework(_ frameworkPath: TSCBasic.AbsolutePath, for cacheKey: CacheKey) async throws {
        // do nothing
    }

    private func versionFilePath(for targetName: String) -> AbsolutePath {
        outputDirectory.appending(component: versionFileName(for: targetName))
    }

    private func versionFileName(for targetName: String) -> String {
        ".\(targetName).version"
    }
}
