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

extension PinsStore.PinState: Codable {
    enum Key: CodingKey {
        case revision
        case branch
        case version
    }
    
    public func encode(to encoder: Encoder) throws {
        var versionContainer = encoder.container(keyedBy: Key.self)
        switch self {
        case .version(let version, let revision):
            try versionContainer.encode(version.description, forKey: .version)
            try versionContainer.encode(revision, forKey: .revision)
        case .revision(let revision):
            try versionContainer.encode(revision, forKey: .revision)
        case .branch(let branchName, let revision):
            try versionContainer.encode(branchName, forKey: .branch)
            try versionContainer.encode(revision, forKey: .revision)
        }
    }
    
    public init(from decoder: Decoder) throws {
        let decoder = try decoder.container(keyedBy: Key.self)
        if decoder.contains(.branch) {
            let branchName = try decoder.decode(String.self, forKey: .branch)
            let revision = try decoder.decode(String.self, forKey: .revision)
            self = .branch(name: branchName, revision: revision)
        } else if decoder.contains(.version) {
            let version = try decoder.decode(Version.self, forKey: .version)
            let revision = try decoder.decode(String?.self, forKey: .revision)
            self = .version(version, revision: revision)
        } else {
            let revision = try decoder.decode(String.self, forKey: .revision)
            self = .revision(revision)
        }
    }
}

extension PinsStore.PinState: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .revision(let revision):
            hasher.combine(revision)
        case .version(let version, let revision):
            hasher.combine(version)
            hasher.combine(revision)
        case .branch(let branchName, let revision):
            hasher.combine(branchName)
            hasher.combine(revision)
        }
    }
}

struct CacheKey: Hashable, Codable, Equatable {
    var targetName: String
    var pin: PinsStore.PinState
    var buildOptions: BuildOptions
    var clangVersion: String
}

protocol CacheStrategy {
    func prepare(for target: ResolvedTarget, cacheKey: CacheKey) async throws
    func existsValidCache(for target: ResolvedTarget, cacheKey: CacheKey) async -> Bool
    func generateCache(for target: ResolvedTarget, cacheKey: CacheKey) async throws
    func fetchArtifacts(for target: ResolvedTarget, cacheKey: CacheKey, to destination: AbsolutePath) async throws
}

struct ProjectCacheStrategy: CacheStrategy {
    private let outputDirectory: AbsolutePath
    private let fileSystem: any FileSystem
    
    init(outputDirectory: AbsolutePath, fileSystem: any FileSystem = localFileSystem) {
        self.outputDirectory = outputDirectory
        self.fileSystem = fileSystem
    }

    func prepare(for target: ResolvedTarget, cacheKey: CacheKey) async throws {
        // do nothing
    }
    
    func existsValidCache(for target: ResolvedTarget, cacheKey: CacheKey) async -> Bool {
        let versionFilePath = versionFilePath(for: target)
        guard fileSystem.exists(versionFilePath) else { return false }
        let decoder = JSONDecoder()
        do {
            let versionFileKey = try decoder.decode(path: versionFilePath, fileSystem: fileSystem, as: CacheKey.self)
            return versionFileKey == cacheKey
        } catch {
            return false
        }
    }
    
    func fetchArtifacts(for target: ResolvedTarget, cacheKey: CacheKey, to destination: AbsolutePath) async throws {
        guard outputDirectory != destination else {
            return
        }
        let versionFileName = versionFileName(for: target)
        try fileSystem.move(from: versionFilePath(for: target),
                            to: destination.appending(component: versionFileName))
    }
    
    func generateCache(for target: ResolvedTarget, cacheKey: CacheKey) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(cacheKey)
        let versionFilePath = versionFilePath(for: target)
        try fileSystem.writeFileContents(versionFilePath, data: data)
    }
    
    private func versionFileName(for target: ResolvedTarget) -> String {
        ".\(target.name).version"
    }
    
    private func versionFilePath(for target: ResolvedTarget) -> AbsolutePath {
        outputDirectory.appending(component: versionFileName(for: target))
    }
}

struct CacheSystem<Strategy: CacheStrategy> {
    private let rootPackage: Package
    private let buildOptions: BuildOptions
    private let strategy: Strategy
    
    enum Error: LocalizedError {
        case revisionNotDetected(String)
        case compilerVersionNotDetected
        
        var errorDescription: String? {
            switch self {
            case .revisionNotDetected(let packageName):
                return "Repository version is not detected for \(packageName)."
            case .compilerVersionNotDetected:
                return "Compiler version not detected. Please check your environment"
            }
        }
    }
    
    init(rootPackage: Package, buildOptions: BuildOptions, strategy: Strategy) {
        self.rootPackage = rootPackage
        self.buildOptions = buildOptions
        self.strategy = strategy
    }

    func prepareCache(subPackage: ResolvedPackage, target: ResolvedTarget) async throws {
        let cacheKey = try await calculateCacheKey(package: subPackage, target: target)
        try await strategy.prepare(for: target, cacheKey: cacheKey)
    }
    
    func generateVersionFile(subPackage: ResolvedPackage, target: ResolvedTarget) async throws {
        let cacheKey = try await calculateCacheKey(package: subPackage, target: target)
        try await strategy.generateCache(for: target, cacheKey: cacheKey)
    }
    
    func existsValidCache(subPackage: ResolvedPackage, target: ResolvedTarget) async -> Bool {
        do {
            let cacheKey = try await calculateCacheKey(package: subPackage, target: target)
            return await strategy.existsValidCache(for: target, cacheKey: cacheKey)
        } catch {
            return false
        }
    }
    
    func fetchArtifacts(subPackage: ResolvedPackage, target: ResolvedTarget, to destination: AbsolutePath) async throws {
        let cacheKey = try await calculateCacheKey(package: subPackage, target: target)
        try await strategy.fetchArtifacts(for: target, cacheKey: cacheKey, to: destination)
    }
    
    private func calculateCacheKey(package: ResolvedPackage, target: ResolvedTarget) async throws -> CacheKey {
        let targetName = target.name
        let pin = try retrievePin(package: package, target: target)
        let buildOptions = buildOptions
        guard let clangVersion = try await ClangChecker().fetchClangVersion() else { throw Error.compilerVersionNotDetected } // TODO DI
        return CacheKey(
            targetName: targetName,
            pin: pin.state,
            buildOptions: buildOptions,
            clangVersion: clangVersion
        )
    }
    
    private func retrievePin(package: ResolvedPackage, target: ResolvedTarget) throws -> PinsStore.Pin {
        let pinsStore = try rootPackage.workspace.pinsStore.load()
        guard let pin = pinsStore.pinsMap[package.identity] else {
            throw Error.revisionNotDetected(package.manifest.displayName)
        }
        return pin
    }
}

extension CacheKey {
    var sha256Hash: String {
        return SHA256().hash(.init(hashValue)).sha256Checksum
    }
}
