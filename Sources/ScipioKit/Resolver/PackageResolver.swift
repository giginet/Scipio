import Foundation
import PackageManifestKit
import OrderedCollections
import AsyncOperations
import Basics

actor PackageResolver {
    // Because `dump-package` is called for each child dependency, all PackageKinds are mistakenly set to `.root`.
    // The manifest's `dependencies` have the correct kinds, so we cache them here.
    private var resolvedPackageKinds: [String: PackageKind] = [:]
    private var allPackages: [_ResolvedPackage.ID: _ResolvedPackage] = [:]
    private var allModules: Set<_ResolvedModule> = []
    private var cachedModuleType: [Target: ResolvedModuleType] = [:]
    private var cachedDependencyManifests: [DependencyPackage: Manifest] = [:]
    private let jsonDecoder = JSONDecoder()

    private let dependencyPackagesByID: [DependencyPackage.ID: DependencyPackage]
    private let dependencyPackagesByName: [String: DependencyPackage]
    // URL of the root package directory.
    private let packageDirectory: URL
    private let rootManifest: Manifest
    private let pins: [Pin.ID: Pin]
    private let manifestLoader: ManifestLoader
    private let fileSystem: any FileSystem

    init(
        packageDirectory: URL,
        rootManifest: Manifest,
        fileSystem: some FileSystem,
        executor: some Executor = ProcessExecutor(decoder: StandardOutputDecoder())
    ) async throws {
        // Run `swift package resolve` and read Package.resolved
        let packageResolved = try await PackageResolveExecutor(fileSystem: fileSystem, executor: executor).execute(packageDirectory: packageDirectory)
        // Run `swift package show-dependencies` and parse dependency tree
        let parseResult = try await ShowDependenciesParser(executor: executor).parse(packageDirectory: packageDirectory)

        self.packageDirectory = packageDirectory
        self.pins = Dictionary(uniqueKeysWithValues: packageResolved?.pins.map { ($0.id, $0) } ?? [])
        self.dependencyPackagesByID = parseResult.dependencyPackagesByID
        self.dependencyPackagesByName = parseResult.dependencyPackagesByName
        self.rootManifest = rootManifest
        self.manifestLoader = ManifestLoader(executor: executor)
        self.fileSystem = fileSystem

        setActualPackageKinds(for: rootManifest)
    }

    /// Start resolving modules and products from the root manifest.
    /// - Returns: Graph containing all resolved packages and modules.
    func resolve() async throws -> _ModulesGraph {
        let rootPackage = try await resolve(manifest: rootManifest)

        return _ModulesGraph(
            rootPackage: rootPackage,
            allPackages: allPackages,
            allModules: allModules
        )
    }

    /// Resolve a manifest into a concrete _ResolvedPackage with modules and products.
    private func resolve(manifest: Manifest) async throws -> _ResolvedPackage {
        let dependencyPackage = resolveDependencyPackage(for: manifest)
        let packageID = _ResolvedPackage.ID(packageKind: manifest.packageKind, packageIdentity: dependencyPackage.identity)

        if let resolvedPackage = allPackages[packageID] {
            return resolvedPackage
        } else {
            let resolvedPackage = _ResolvedPackage(
                manifest: manifest,
                resolvedPackageKind: resolvedPackageKinds[packageID.packageIdentity] ?? manifest.packageKind,
                packageIdentity: dependencyPackage.identity,
                pinState: pins[dependencyPackage.identity]?.state,
                path: dependencyPackage.path,
                targets: try await manifest.targets.filter { Target.TargetKind.enabledKinds.contains($0.type) }.asyncMap {
                    try await self.resolve(
                        target: $0,
                        in: manifest
                    )
                },
                products: try await manifest.products.asyncMap {
                    try await self.resolve(
                        product: $0,
                        in: manifest
                    )
                }
            )
            allPackages[resolvedPackage.id] = resolvedPackage
            return resolvedPackage
        }
    }

    /// Resolve a dependency by name within a manifest.
    private func resolve(
        byName: String,
        condition: PackageCondition?,
        dependencyPackage: DependencyPackage,
        in manifest: Manifest
    ) async throws -> _ResolvedModule.Dependency? {
        if let target = manifest.targets.first(where: { $0.name == byName }) {
            return try await .module(
                resolve(target: target, in: manifest, dependencyPackage: dependencyPackage),
                conditions: normalizeConditions(condition)
            )
        } else {
            let packageName = manifest.dependencies.compactMap { packageDependency in
                switch packageDependency {
                case .fileSystem(let fileSystem):
                    fileSystem.nameForTargetDependencyResolutionOnly
                case .sourceControl(let sourceControl):
                    sourceControl.nameForTargetDependencyResolutionOnly
                case .registry(let registry):
                    registry.identity
                }
            }.first { $0 == byName }

            let resolvedProduct = try await resolve(
                productName: byName,
                packageName: packageName,
                in: manifest
            )

            guard let resolvedProduct else {
                return nil
            }

            return .product(resolvedProduct, conditions: normalizeConditions(condition))
        }
    }

    /// Resolve a list of target dependencies into resolved dependencies.
    private func resolve(
        dependencies: [PackageManifestKit.Target.Dependency],
        in manifest: Manifest
    ) async throws -> [_ResolvedModule.Dependency] {
        let dependencyPackage = resolveDependencyPackage(for: manifest)

        return try await dependencies.asyncCompactMap { dependency -> _ResolvedModule.Dependency? in
            switch dependency {
            case .target(let name, let condition):
                guard let target = manifest.targets.first(where: { $0.name == name }) else {
                    return nil
                }

                return try await .module(
                    self.resolve(target: target, in: manifest, dependencyPackage: dependencyPackage),
                    conditions: self.normalizeConditions(condition)
                )

            case .byName(let name, let condition):
                return try await self.resolve(
                    byName: name,
                    condition: condition,
                    dependencyPackage: dependencyPackage,
                    in: manifest
                )

            case .product(let name, let package, _, let condition):
                let resolvedProduct = try await self.resolve(
                    productName: name,
                    packageName: package,
                    in: manifest
                )

                guard let resolvedProduct else {
                    return nil
                }

                return await .product(resolvedProduct, conditions: self.normalizeConditions(condition))
            }
        }
    }

    // Resolve the product from a dependency of the manifest
    private func resolve(
        productName: String,
        packageName: String?,
        in manifest: Manifest
    ) async throws -> _ResolvedProduct? {
        let packageName = packageName ?? productName

        guard let dependencyPackage = resolveDependencyPackage(packageName) else {
            return nil
        }

        let manifest = try await loadManifest(for: dependencyPackage)
        let resolvedPackage = try await self.resolve(manifest: manifest)

        guard let resolvedProduct = resolvedPackage.products.first(where: { $0.name == productName }) else {
            return nil
        }

        return resolvedProduct
    }

    /// Resolve a manifest Product into a _ResolvedProductt
    private func resolve(
        product: Product,
        in manifest: PackageManifestKit.Manifest
    ) async throws -> _ResolvedProduct {
        let packageIdentity = resolveDependencyPackage(for: manifest).identity

        return _ResolvedProduct(
            underlying: product,
            modules: try await product.targets
                .compactMap { targetName in manifest.targets.first(where: { $0.name == targetName }) }
                .filter { Target.TargetKind.enabledKinds.contains($0.type) }
                .asyncMap { try await self.resolve(target: $0, in: manifest) },
            type: product.type,
            packageID: _ResolvedPackage.ID(packageKind: manifest.packageKind, packageIdentity: packageIdentity)
        )
    }

    /// Resolve a DependencyPackage from the given package name
    private func resolveDependencyPackage(
        _ packageName: String
    ) -> DependencyPackage? {
        // packageName can be different between `show-dependencies` and `dump-package`, so we try all possible cases
        if let dependencyPackage = dependencyPackagesByName[packageName] {
            dependencyPackage
        } else if let dependencyPackage = dependencyPackagesByID[packageName] {
            dependencyPackage
        } else if let dependencyPackage = dependencyPackagesByID[packageName.lowercased()] {
            dependencyPackage
        } else {
            nil
        }
    }

    /// Resolve a manifest Target into a _ResolvedModule.
    private func resolve(
        target: Target,
        in manifest: PackageManifestKit.Manifest
    ) async throws -> _ResolvedModule {
        let dependencyPackage = resolveDependencyPackage(for: manifest)

        return try await resolve(
            target: target,
            in: manifest,
            dependencyPackage: dependencyPackage
        )
    }

    /// Resolve a manifest Target into a _ResolvedModule.
    private func resolve(
        target: Target,
        in manifest: Manifest,
        dependencyPackage: DependencyPackage
    ) async throws -> _ResolvedModule {
        guard case let .root(localPackageURL) = manifest.packageKind else {
            preconditionFailure(
                "manifest.packageKind must be .root because ManifestLoader.loadManifest is invoked for each dependency, so every loaded manifest is treated as a root package."
            )
        }

        let module = try await _ResolvedModule(
            underlying: target,
            dependencies: resolve(dependencies: target.dependencies, in: manifest),
            localPackageURL: localPackageURL,
            packageID: _ResolvedPackage.ID(packageKind: manifest.packageKind, packageIdentity: dependencyPackage.identity),
            resolvedModuleType: resolveModuleType(of: target, dependencyPackage: dependencyPackage)
        )
        allModules.insert(module)
        return module
    }

    /// Normalizes an optional PackageCondition into an array.
    private func normalizeConditions(_ condition: PackageCondition?) -> [PackageCondition] {
        return condition.map { [$0] } ?? []
    }

    /// Determines the type of a module (e.g., Swift, Clang, binary) for a given target.
    private func resolveModuleType(
        of target: Target,
        dependencyPackage: DependencyPackage
    ) -> ResolvedModuleType {
        if let cachedModuleType = cachedModuleType[target] {
            return cachedModuleType
        }

        let resolvedModuleType = ModuleTypeResolver(
            fileSystem: fileSystem,
            rootPackageDirectory: packageDirectory,
            target: target,
            dependencyPackage: dependencyPackage
        ).resolve()

        cachedModuleType[target] = resolvedModuleType

        return resolvedModuleType
    }

    private func resolveDependencyPackage(for manifest: Manifest) -> DependencyPackage {
        guard let dependencyPackage = dependencyPackagesByName[manifest.name] else {
            fatalError("Manifest \(manifest.name) refers to unknown package")
        }
        return dependencyPackage
    }

    private func loadManifest(for dependencyPackage: DependencyPackage) async throws -> Manifest {
        if let cachedManifest = cachedDependencyManifests[dependencyPackage] {
            return cachedManifest
        } else {
            let manifest = try await manifestLoader.loadManifest(for: dependencyPackage)
            setActualPackageKinds(for: manifest)
            cachedDependencyManifests[dependencyPackage] = manifest
            return manifest
        }
    }

    private func setActualPackageKinds(for manifest: Manifest) {
        let actualPackageKinds = manifest.dependencies.reduce(into: [String: PackageKind]()) { partialResult, dependency in
            switch dependency {
            case .fileSystem(let fileSystem):
                partialResult.updateValue(.fileSystem(fileSystem.path), forKey: fileSystem.identity)
            case .registry(let registry):
                partialResult.updateValue(.registry(registry.identity), forKey: registry.identity)
            case .sourceControl(let sourceControl):
                switch sourceControl.location {
                case .local(let localURL):
                    partialResult.updateValue(.localSourceControl(localURL), forKey: sourceControl.identity)
                case .remote:
                    partialResult.updateValue(.remoteSourceControl(""), forKey: sourceControl.identity)
                }
            }
        }
        self.resolvedPackageKinds.merge(actualPackageKinds) { _, new in new }
    }
}

private struct ModuleTypeResolver {
    let fileSystem: any FileSystem
    let rootPackageDirectory: URL
    let target: Target
    let dependencyPackage: DependencyPackage

    let clangFileTypes = ["c", "m", "mm", "cc", "cpp", "cxx"]
    let asmFileTypes = ["s", "S"]
    let swiftFileType = "swift"

    /// Determine module type based on target type and source files.
    func resolve() -> ResolvedModuleType {
        switch target.type {
        case .binary:
            resolveModuleTypeForBinary()
        default:
            resolveModuleTypeForLibrary()
        }
    }

    private func resolveModuleTypeForBinary() -> ResolvedModuleType {
        assert(target.type == .binary)

        let artifactType: ResolvedModuleType.BinaryArtifactLocation = {
            let artifactsLocation: ResolvedModuleType.BinaryArtifactLocation = .remote(packageIdentity: dependencyPackage.identity, name: target.name)
            let artifactsURL = artifactsLocation.artifactURL(rootPackageDirectory: rootPackageDirectory).spmAbsolutePath

            return if fileSystem.exists(artifactsURL) {
                artifactsLocation
            } else {
                .local(resolveTargetFullPath(target: target))
            }
        }()

        return .binary(artifactType)
    }

    private func resolveModuleTypeForLibrary() -> ResolvedModuleType {
        assert(target.type != .binary)

        let moduleFullPath = resolveTargetFullPath(target: target)
        let moduleSourcesFullPaths = target.sources?.map { moduleFullPath.appending(component: $0) } ?? [moduleFullPath]
        let moduleExcludeFullPaths = target.exclude.map { moduleFullPath.appending(component: $0) }
        let publicHeadersPath = target.publicHeadersPath ?? "include"
        let includeDir = moduleFullPath.appendingPathComponent(publicHeadersPath)

        let sources: [URL] = moduleSourcesFullPaths.flatMap { source in
            FileManager.default
                .enumerator(at: source, includingPropertiesForKeys: nil)?
                .lazy
                .compactMap { $0 as? URL }
                .filter { url in
                    moduleExcludeFullPaths.allSatisfy { !url.path.hasPrefix($0.path) }
                } ?? []
        }

        let hasSwiftSources = sources.contains { $0.pathExtension == swiftFileType }
        let hasClangSources = sources.contains { (clangFileTypes + asmFileTypes).contains($0.pathExtension) }

        // In SwiftPM, the module type (ClangModule or SwiftModule) is determined by checking the file extensions inside the module.
        return if hasSwiftSources && hasClangSources {
            // TODO: Update when SwiftPM supports mixed-language targets.
            // Currently SwiftPM cannot mix Swift and C/Assembly in one target.
            // ref: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0403-swiftpm-mixed-language-targets.md
            fatalError("Mixed-language target are not supported yet.")
        } else if hasSwiftSources {
            .swift
        } else {
            .clang(includeDir: includeDir)
        }
    }

    private func resolveTargetFullPath(target: Target) -> URL {
        let packagePath = dependencyPackage.path
        // In SwiftPM, if target does not specify a path,
        // it is assumed to be located at 'Sources/<target name>' by default.
        // For Clang modules, the default is 'src/<target name>'.
        let defaultSwiftModulePath = "Sources/\(target.name)"
        let defaultClangModulePath = "src/\(target.name)"
        let swiftModuleRelativePath = target.path ?? defaultSwiftModulePath
        let swiftModuleFullPath = URL(fileURLWithPath: packagePath).appending(component: swiftModuleRelativePath)
        let clangModuleFullPath = URL(fileURLWithPath: packagePath).appending(component: defaultClangModulePath)

        return if fileSystem.exists(swiftModuleFullPath.spmAbsolutePath) {
            swiftModuleFullPath
        } else if fileSystem.exists(clangModuleFullPath.spmAbsolutePath) {
            clangModuleFullPath
        } else {
            preconditionFailure("Cannot find module directory for target '\(target.name)'")
        }
    }
}

private struct PackageResolveExecutor: @unchecked Sendable {
    private let executor: any Executor
    private let fileSystem: any FileSystem
    private let jsonDecoder = JSONDecoder()

    init(fileSystem: some FileSystem, executor: some Executor) {
        self.fileSystem = fileSystem
        self.executor = executor
    }

    func execute(packageDirectory: URL) async throws -> PackageResolved? {
        let commands = [
            "/usr/bin/xcrun",
            "swift",
            "package",
            "resolve",
            "--package-path",
            packageDirectory.path(percentEncoded: false),
        ]

        try await executor.execute(commands)

        let packageResolvedPath = packageDirectory.appending(component: "Package.resolved").spmAbsolutePath

        guard fileSystem.exists(packageResolvedPath) else {
            return nil
        }

        guard let packageResolvedString = try fileSystem.readFileContents(packageResolvedPath).validDescription else {
            throw Error.cannotReadPackageResolvedFile
        }

        let packageResolved = try jsonDecoder.decode(PackageResolved.self, from: packageResolvedString)

        return packageResolved
    }

    enum Error: Swift.Error {
        case cannotReadPackageResolvedFile
    }
}

/// Parses the output of `swift package show-dependencies`.
private struct ShowDependenciesParser: @unchecked Sendable {
    private struct ShowDependenciesResponse: Decodable {
        var identity: String
        var name: String
        var url: String
        var version: String
        var path: String
        var dependencies: [ShowDependenciesResponse]?
    }

    struct DependencyPackages {
        var dependencyPackagesByID: [DependencyPackage.ID: DependencyPackage]
        var dependencyPackagesByName: [String: DependencyPackage]
    }

    let executor: any Executor
    let jsonDecoder = JSONDecoder()

    init(executor: some Executor) {
        self.executor = executor
    }

    func parse(packageDirectory: URL) async throws -> DependencyPackages {
        let commands = [
            "/usr/bin/xcrun",
            "swift",
            "package",
            "show-dependencies",
            "--package-path",
            packageDirectory.path,
            "--format",
            "json",
        ]

        let dependencyString = try await executor.execute(commands).unwrapOutput()
        let dependency = try jsonDecoder.decode(ShowDependenciesResponse.self, from: dependencyString)
        return flattenPackages(dependency)
    }

    private func flattenPackages(_ package: ShowDependenciesResponse) -> DependencyPackages {
        var dependencyPackagesByID: [DependencyPackage.ID: DependencyPackage] = [:]
        var dependencyPackagesByName: [String: DependencyPackage] = [:]

        func traverse(_ package: ShowDependenciesResponse) {
            let dependencyPackage = DependencyPackage(
                identity: package.identity,
                name: package.name,
                url: package.url,
                version: package.version,
                path: package.path
            )
            dependencyPackagesByID[dependencyPackage.id] = dependencyPackage
            dependencyPackagesByName[dependencyPackage.name] = dependencyPackage
            package.dependencies?.forEach { traverse($0) }
        }

        traverse(package)

        return DependencyPackages(
            dependencyPackagesByID: dependencyPackagesByID,
            dependencyPackagesByName: dependencyPackagesByName
        )
    }
}
