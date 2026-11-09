import CacheStorage
import CryptoKit
import Foundation
import ScipioKitCore

public struct MacroCacheKey: CacheKey {
    public struct Dependency: Codable, Hashable, Sendable {
        public let packageIdentity: String
        public let pin: Pin.State
        public let targetName: String
    }

    public let schemaVersion: Int
    public let artifactKind: ArtifactKind
    public let targetName: String
    public let dependencies: [Dependency]
    public let swiftVersion: String
    public let clangVersion: String
    public let xcodeVersion: String
    public let hostArchitecture: String
    public let deploymentTarget: String?
    public let rootMacOSPlatform: String?
    public let configuration: String
    public let scipioVersion: String?
}

public struct MacroVersionFileDecoder {
    public enum Error: Swift.Error {
        case unsupportedSchemaVersion(Int)
    }

    private let fileSystem: any FileSystem

    public init(fileSystem: any FileSystem = LocalFileSystem.default) {
        self.fileSystem = fileSystem
    }

    public func decode(versionFile: URL) throws -> MacroCacheKey {
        let data = try fileSystem.readFileContents(versionFile)
        let key = try JSONDecoder().decode(MacroCacheKey.self, from: data)
        guard key.schemaVersion == 1 else { throw Error.unsupportedSchemaVersion(key.schemaVersion) }
        return key
    }
}

struct MacroPlugin: Sendable {
    let targetName: String
    let moduleName: String
    let executable: URL
    let cacheKey: MacroCacheKey?
}

struct MacroBuildPlan {
    let modules: [ResolvedModule]
    let targetDependencies: [String: [String]]
    let hostOnlyDependencies: [String: Set<String>]

    init(graph: DependencyGraph<BuildProduct>) throws {
        var plugins: [String: ResolvedModule] = [:]
        var targetDependencies: [String: [String]] = [:]
        var hostOnlyDependencies: [String: Set<String>] = [:]
        for node in graph.allNodes {
            let target = node.value.target
            let macros = target.dependencies.flatMap(\.modules).filter { $0.underlying.type == .macro }
            for macro in macros {
                if let existing = plugins[macro.c99name],
                   existing.packageID != macro.packageID || existing.name != macro.name {
                    throw Error.duplicateModule(macro.c99name)
                }
                plugins[macro.c99name] = macro
            }
            if !macros.isEmpty {
                targetDependencies[target.name] = Set(macros.map(\.c99name)).sorted()
                var hostNames: Set<String> = []
                var runtimeNames: Set<String> = []
                var hostVisited: Set<ResolvedModule> = []
                var runtimeVisited: Set<ResolvedModule> = []

                func collect(_ dependencies: [ResolvedModule.Dependency], names: inout Set<String>, visited: inout Set<ResolvedModule>) {
                    for dependency in dependencies {
                        if let product = dependency.product {
                            names.insert(product.name)
                        }
                        for module in dependency.modules where visited.insert(module).inserted {
                            names.insert(module.name)
                            collect(module.dependencies, names: &names, visited: &visited)
                        }
                    }
                }
                collect(target.dependencies.filter { $0.modules.contains { $0.underlying.type == .macro } },
                        names: &hostNames, visited: &hostVisited)
                collect(target.dependencies.filter { !$0.modules.contains { $0.underlying.type == .macro } },
                        names: &runtimeNames, visited: &runtimeVisited)
                hostOnlyDependencies[target.name] = hostNames.subtracting(runtimeNames)
            }
        }
        self.modules = plugins.values.sorted { $0.c99name < $1.c99name }
        self.targetDependencies = targetDependencies
        self.hostOnlyDependencies = hostOnlyDependencies
    }

    enum Error: LocalizedError {
        case duplicateModule(String)

        var errorDescription: String? {
            switch self {
            case .duplicateModule(let name): "Multiple macro targets use the module name \(name)."
            }
        }
    }
}

struct MacroPluginProducer {
    private struct ArtifactManifest: Codable {
        let executable: String
        let files: [String: String]
    }

    private struct OutputManifest: Codable {
        struct Plugin: Codable {
            let module: String
            let executable: String
            let targets: [String]
        }
        let plugins: [Plugin]
    }

    enum Error: LocalizedError {
        case missingExecutable(String)
        case unresolvedPackage(String)
        case invalidArtifact(String)
        case unsupportedProducer(String)
        case uncacheable(String)

        var errorDescription: String? {
            switch self {
            case .missingExecutable(let name):
                "SwiftPM did not produce the macro executable for \(name)."
            case .unresolvedPackage(let name):
                "Could not find the resolved package for macro dependency \(name)."
            case .invalidArtifact(let name):
                "The macro artifact for \(name) is incomplete or not executable."
            case .unsupportedProducer(let name):
                "Macro artifact publication requires an artifact-capable producer: \(name)."
            case .uncacheable(let name):
                "Macro artifact publication requires pinned dependencies for \(name)."
            }
        }
    }

    private let package: DescriptionPackage
    private let outputDirectory: URL
    private let policies: [Runner.Options.FrameworkCachePolicy]
    private let requireArtifactStorage: Bool
    private let executor: any Executor
    private let manager = FileManager.default
    private let configuration = "debug"

    init(
        package: DescriptionPackage,
        outputDirectory: URL,
        policies: [Runner.Options.FrameworkCachePolicy],
        requireArtifactStorage: Bool = false,
        executor: any Executor = ProcessExecutor(errorDecoder: StandardOutputDecoder())
    ) {
        self.package = package
        self.outputDirectory = outputDirectory
        self.policies = policies
        self.requireArtifactStorage = requireArtifactStorage
        self.executor = executor
    }

    func planPlugins(_ plan: MacroBuildPlan) async throws -> [String: MacroPlugin] {
        guard !plan.modules.isEmpty else { return [:] }
        if requireArtifactStorage {
            let producers = policies.filter {
                $0.actors.contains(.producer) && !($0.storage is ProjectCacheStorage)
            }
            guard !producers.isEmpty else { throw Error.unsupportedProducer("none configured") }
            for policy in producers where !(policy.storage is any ArtifactCacheStorage) {
                throw Error.unsupportedProducer(policy.storage.displayName)
            }
        }
        let swiftVersion = try await run(["/usr/bin/xcrun", "swift", "--version"])
        let clangVersion = try await run(["/usr/bin/xcrun", "clang", "--version"])
        let xcodeVersion = try await run(["/usr/bin/xcrun", "xcodebuild", "-version"])
        let architecture = try await run(["/usr/bin/arch"])
        var plugins: [String: MacroPlugin] = [:]

        for module in plan.modules {
            let key = try cacheKey(
                for: module, swiftVersion: swiftVersion, clangVersion: clangVersion,
                xcodeVersion: xcodeVersion, architecture: architecture
            )
            if key == nil && requireArtifactStorage { throw Error.uncacheable(module.name) }
            let directory = outputDirectory.appendingPathComponent(module.c99name)
            let plugin = MacroPlugin(
                targetName: module.name, moduleName: module.c99name,
                executable: directory.appendingPathComponent(module.c99name), cacheKey: key
            )
            plugins[module.c99name] = plugin
        }
        return plugins
    }

    func produce(_ plan: MacroBuildPlan, plugins: [String: MacroPlugin]) async throws {
        if plan.modules.isEmpty {
            let metadata = outputDirectory.appendingPathComponent("plugins.json")
            if manager.fileExists(atPath: metadata.path) {
                try JSONEncoder().encode(OutputManifest(plugins: [])).write(to: metadata, options: .atomic)
            }
            return
        }
        try manager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        for module in plan.modules {
            guard let plugin = plugins[module.c99name] else { throw Error.missingExecutable(module.name) }
            let key = plugin.cacheKey
            let directory = outputDirectory.appendingPathComponent(module.c99name)
            let versionFile = outputDirectory.appendingPathComponent(".\(module.c99name).version")
            if !policies.isEmpty, let key, validOutput(directory, versionFile: versionFile, key: key) {
                try await publish(directory, key: key)
                continue
            }

            var restored = false
            if let key {
                for policy in policies where policy.actors.contains(.consumer) {
                    guard let storage = policy.storage as? any ArtifactCacheStorage else {
                        logger.info("Macro cache is not supported by \(policy.storage.displayName); skipping it.")
                        continue
                    }
                    let staging = outputDirectory.appendingPathComponent(".restore-\(UUID().uuidString)")
                    defer { try? manager.removeItem(at: staging) }
                    do {
                        guard try await storage.existsArtifact(for: key, kind: .macroPlugin) else { continue }
                        try await storage.fetchArtifact(for: key, kind: .macroPlugin, to: staging)
                        guard validateArtifact(staging, executable: module.c99name) else {
                            try await storage.removeArtifact(for: key, kind: .macroPlugin)
                            continue
                        }
                        try install(staging, at: directory, versionFile: versionFile, key: key)
                        restored = true
                        break
                    } catch {
                        logger.warning("Macro cache restore failed for \(module.name): \(error.localizedDescription)")
                    }
                }
            }

            if !restored {
                let staging = outputDirectory.appendingPathComponent(".build-\(UUID().uuidString)")
                defer { try? manager.removeItem(at: staging) }
                try await build(module, into: staging)
                guard validateArtifact(staging, executable: module.c99name) else {
                    throw Error.invalidArtifact(module.name)
                }
                try install(staging, at: directory, versionFile: versionFile, key: policies.isEmpty ? nil : key)
            }
            if let key { try await publish(directory, key: key) }
        }

        let output = OutputManifest(plugins: plugins.values.sorted { $0.moduleName < $1.moduleName }.map {
            let plugin = $0
            return .init(
                module: plugin.moduleName,
                executable: "\(plugin.moduleName)/\(plugin.moduleName)",
                targets: plan.targetDependencies.filter { $0.value.contains(plugin.moduleName) }.map(\.key).sorted()
            )
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(output).write(to: outputDirectory.appendingPathComponent("plugins.json"), options: .atomic)
    }

    private func cacheKey(
        for module: ResolvedModule, swiftVersion: String, clangVersion: String,
        xcodeVersion: String, architecture: String
    ) throws -> MacroCacheKey? {
        let modules = [module] + (try module.recursiveModuleDependencies())
        var dependencies: [MacroCacheKey.Dependency] = []
        for dependency in Set(modules) {
            guard let resolvedPackage = package.graph.package(for: dependency) else {
                throw Error.unresolvedPackage(dependency.name)
            }
            guard let pin = resolvedPackage.pinState else {
                logger.info("Macro cache disabled for \(module.name): \(resolvedPackage.name) has no pinned revision.")
                return nil
            }
            dependencies.append(.init(
                packageIdentity: resolvedPackage.id.packageIdentity,
                pin: pin, targetName: dependency.name
            ))
        }
        dependencies.sort {
            ($0.packageIdentity, $0.targetName) < ($1.packageIdentity, $1.targetName)
        }
        return MacroCacheKey(
            schemaVersion: 1, artifactKind: .macroPlugin, targetName: module.c99name,
            dependencies: dependencies, swiftVersion: swiftVersion, clangVersion: clangVersion,
            xcodeVersion: xcodeVersion, hostArchitecture: architecture,
            deploymentTarget: ProcessInfo.processInfo.environment["MACOSX_DEPLOYMENT_TARGET"],
            rootMacOSPlatform: package.manifest.platforms?
                .first(where: { $0.platformName.lowercased() == "macos" })?.version,
            configuration: configuration, scipioVersion: currentScipioVersion
        )
    }

    private func publish(_ directory: URL, key: MacroCacheKey) async throws {
        for policy in policies where policy.actors.contains(.producer) {
            guard let storage = policy.storage as? any ArtifactCacheStorage else {
                if !(policy.storage is ProjectCacheStorage) {
                    logger.warning("Macro cache is not supported by \(policy.storage.displayName); skipping upload.")
                }
                continue
            }
            do {
                if try await !storage.existsArtifact(for: key, kind: .macroPlugin) {
                    try await storage.cacheArtifact(directory, for: key, kind: .macroPlugin)
                }
            } catch {
                if requireArtifactStorage { throw error }
                logger.warning("Macro cache write failed for \(key.targetName): \(error.localizedDescription)")
            }
        }
    }

    private func build(_ module: ResolvedModule, into directory: URL) async throws {
        let common = [
            "/usr/bin/xcrun", "swift", "build", "--build-system", "native",
            "--package-path", package.packageDirectory.path(percentEncoded: false),
            "--configuration", configuration, "--disable-automatic-resolution",
        ]
        logger.info("Building macOS macro plugin \(module.name)")
        _ = try await run(common + ["--product", module.name])
        let binPath = try await run(common + ["--show-bin-path"])
        let binDirectory = URL(filePath: binPath)
        let executable = binDirectory.appendingPathComponent("\(module.name)-tool")
        guard manager.isExecutableFile(atPath: executable.path) else {
            throw Error.missingExecutable(module.name)
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try manager.copyItem(at: executable, to: directory.appendingPathComponent(module.c99name))
        let supportFiles = try manager.contentsOfDirectory(atPath: binDirectory.path)
            .filter { $0.hasSuffix(".bundle") || $0.hasSuffix(".dylib") }.sorted()
        for name in supportFiles {
            try manager.copyItem(at: binDirectory.appendingPathComponent(name), to: directory.appendingPathComponent(name))
        }
        let manifest = ArtifactManifest(executable: module.c99name, files: try artifactFiles(directory))
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("artifact.json"), options: .atomic)
    }

    private func run(_ arguments: [String]) async throws -> String {
        try await executor.execute(arguments).unwrapOutput().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func validateArtifact(_ directory: URL, executable: String) -> Bool {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("artifact.json")),
              let manifest = try? JSONDecoder().decode(ArtifactManifest.self, from: data),
              manifest.executable == executable,
              manager.isExecutableFile(atPath: directory.appendingPathComponent(executable).path)
        else { return false }
        do {
            let files = try artifactFiles(directory)
            if files != manifest.files {
                logger.warning("Macro artifact content validation failed at \(directory.path).")
                return false
            }
            return true
        } catch {
            logger.warning("Macro artifact validation failed: \(error.localizedDescription)")
            return false
        }
    }

    private func artifactFiles(_ directory: URL) throws -> [String: String] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var files: [String: String] = [:]
        for relativePath in try manager.subpathsOfDirectory(atPath: directory.path) {
            if relativePath == "artifact.json" { continue }
            let url = directory.appendingPathComponent(relativePath)
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                files[relativePath] = "link:" + (try manager.destinationOfSymbolicLink(atPath: url.path))
            } else if values.isDirectory == true {
                files[relativePath] = "directory"
            } else if values.isRegularFile == true {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                files[relativePath] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            } else {
                throw Error.invalidArtifact(directory.lastPathComponent)
            }
        }
        return files
    }

    private func validOutput(_ directory: URL, versionFile: URL, key: MacroCacheKey) -> Bool {
        guard let stored = try? MacroVersionFileDecoder().decode(versionFile: versionFile),
              stored == key
        else { return false }
        return validateArtifact(directory, executable: key.targetName)
    }

    private func install(_ staging: URL, at directory: URL, versionFile: URL, key: MacroCacheKey?) throws {
        try? manager.removeItem(at: versionFile)
        if manager.fileExists(atPath: directory.path) {
            try manager.removeItem(at: directory)
        }
        try manager.moveItem(at: staging, to: directory)
        if let key {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(key).write(to: versionFile, options: .atomic)
        }
    }
}
