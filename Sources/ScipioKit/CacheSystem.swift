import Foundation
import TSCUtility
import PackageGraph
import TSCBasic

struct ClangChecker<E: Executor> {
    private let executor: E

    init(executor: E = ProcessExecutor()) {
        self.executor = executor
    }

    func fetchClangVersion() async throws -> String? {
        let result = try await executor.execute("/usr/bin/xcrun", "clang", "--version")
        let rawString = try result.unwrapOutput()
        return parseClangVersion(from: rawString)
    }

    private func parseClangVersion(from outputString: String) -> String? {
        // TODO Use modern regex
        let regex = try! NSRegularExpression(pattern: "Apple\\sclang\\sversion\\s.+\\s\\((?<version>.+)\\)")
        return regex.matches(in: outputString, range: NSMakeRange(0, outputString.utf16.count)).compactMap { match -> String? in
            guard let version = match.captured(by: "version", in: outputString) else { return nil }
            return version
        }.first
    }
}

struct CacheSystem {
    private let rootPackage: Package
    private let outputDirectory: AbsolutePath
    private let buildOptions: BuildOptions
    private let fileSystem: any FileSystem

    enum Error: Swift.Error {
        case revisionNotDetected(String)
        case compilerVersionNotDetected
    }

    init(rootPackage: Package, outputDirectory: AbsolutePath, buildOptions: BuildOptions, fileSystem: any FileSystem = localFileSystem) {
        self.rootPackage = rootPackage
        self.outputDirectory = outputDirectory
        self.buildOptions = buildOptions
        self.fileSystem = fileSystem
    }

    private func versionFilePath(for target: ResolvedTarget) -> AbsolutePath {
        outputDirectory.appending(component: ".\(target.name).version")
    }

    func generateVersionFile(package: ResolvedPackage, target: ResolvedTarget) async throws {
        let key = try await calculateCacheKey(package: package, target: target)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(key)
        let versionFilePath = versionFilePath(for: target)
        try fileSystem.writeFileContents(versionFilePath, data: data)
    }

    func existsValidCache(package: ResolvedPackage, target: ResolvedTarget) async throws -> Bool {
        let versionFilePath = versionFilePath(for: target)
        guard fileSystem.exists(versionFilePath) else { return false }
        let decoder = JSONDecoder()
        let versionFileKey = try decoder.decode(path: versionFilePath, fileSystem: fileSystem, as: CacheKey.self)
        let expectedKey = try await calculateCacheKey(package: package, target: target)
        return versionFileKey == expectedKey
    }

    private func calculateCacheKey(package: ResolvedPackage, target: ResolvedTarget) async throws -> CacheKey {
        let targetName = target.name
        guard let revision = package.manifest.version?.description ?? package.manifest.revision else {
            throw Error.revisionNotDetected(targetName)
        }
        let buildOptions = buildOptions
        guard let clangVersion = try await ClangChecker().fetchClangVersion() else { throw Error.compilerVersionNotDetected } // TODO DI
        return CacheKey(targetName: targetName, revision: revision, buildOptions: buildOptions, clangVersion: clangVersion)
    }

    struct CacheKey: Hashable, Codable, Equatable {
        var targetName: String
        var revision: String
        var buildOptions: BuildOptions
        var clangVersion: String
    }
}
