import Foundation
import PackageManifestKit
import OrderedCollections
import AsyncOperations

actor PackageResolver {
    // Because `dump-package` is called for each child dependency, all PackageKinds are mistakenly set to `.root`.
    // The manifest's `dependencies` have the correct kinds, so we cache them here.
    private var resolvedPackageKinds: [String: PackageKind] = [:]
    private var allPackages: [PackageID: ResolvedPackage] = [:]
    private var allModules: Set<ResolvedModule> = []
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
    private let moduleTypeResolver: ModuleTypeResolver
    private let fileSystem: any FileSystem

    init(
        packageDirectory: URL,
        rootManifest: Manifest,
        fileSystem: some FileSystem,
        executor: some Executor = ProcessExecutor(errorDecoder: StandardOutputDecoder())
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
        self.moduleTypeResolver = ModuleTypeResolver(fileSystem: fileSystem, rootPackageDirectory: packageDirectory)
        self.fileSystem = fileSystem

        setActualPackageKinds(for: rootManifest)
    }

    /// Start resolving modules and products from the root manifest.
    /// - Returns: Graph containing all resolved packages and modules.
    func resolve() async throws -> ModulesGraph {
        let rootPackage = try await resolve(manifest: rootManifest)

        return ModulesGraph(
            rootPackage: rootPackage,
            allPackages: allPackages,
            allModules: allModules
        )
    }

    /// Resolve a manifest into a concrete ResolvedPackage with modules and products.
    private func resolve(manifest: Manifest) async throws -> ResolvedPackage {
        let dependencyPackage = resolveDependencyPackage(for: manifest)
        let packageID = PackageID(packageKind: manifest.packageKind, packageIdentity: dependencyPackage.identity)

        if let resolvedPackage = allPackages[packageID] {
            return resolvedPackage
        } else {
            let resolvedPackage = ResolvedPackage(
                manifest: manifest,
                resolvedPackageKind: resolvedPackageKinds[packageID.packageIdentity] ?? manifest.packageKind,
                packageIdentity: dependencyPackage.identity,
                pinState: pins[dependencyPackage.identity]?.state,
                path: dependencyPackage.path,
                targets: try await manifest.targets.filter { shouldBuild($0.type) }.asyncMap {
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
        by name: String,
        condition: PackageCondition?,
        dependencyPackage: DependencyPackage,
        in manifest: Manifest
    ) async throws -> ResolvedModule.Dependency? {
        if let target = manifest.targets.first(where: { $0.name == name }) {
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
            }.first { $0 == name }

            let resolvedProduct = try await resolve(
                productName: name,
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
    ) async throws -> [ResolvedModule.Dependency] {
        let dependencyPackage = resolveDependencyPackage(for: manifest)

        return try await dependencies.asyncCompactMap { dependency -> ResolvedModule.Dependency? in
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
                    by: name,
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
    ) async throws -> ResolvedProduct? {
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

    /// Resolve a manifest Product into a ResolvedProductt
    private func resolve(
        product: Product,
        in manifest: PackageManifestKit.Manifest
    ) async throws -> ResolvedProduct {
        let packageIdentity = resolveDependencyPackage(for: manifest).identity

        return ResolvedProduct(
            underlying: product,
            modules: try await product.targets
                .compactMap { targetName in manifest.targets.first(where: { $0.name == targetName }) }
                .filter { shouldBuild($0.type) }
                .asyncMap { try await self.resolve(target: $0, in: manifest) },
            type: product.type,
            packageID: PackageID(packageKind: manifest.packageKind, packageIdentity: packageIdentity)
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

    /// Resolve a manifest Target into a ResolvedModule.
    private func resolve(
        target: Target,
        in manifest: PackageManifestKit.Manifest
    ) async throws -> ResolvedModule {
        let dependencyPackage = resolveDependencyPackage(for: manifest)

        return try await resolve(
            target: target,
            in: manifest,
            dependencyPackage: dependencyPackage
        )
    }

    /// Resolve a manifest Target into a ResolvedModule.
    private func resolve(
        target: Target,
        in manifest: Manifest,
        dependencyPackage: DependencyPackage
    ) async throws -> ResolvedModule {
        guard case let .root(localPackageURL) = manifest.packageKind else {
            preconditionFailure(
                """
                manifest.packageKind must be .root because ManifestLoader.loadManifest is invoked for each dependency,
                so every loaded manifest is treated as a root package."
                """
            )
        }

        let module = try await ResolvedModule(
            underlying: target,
            dependencies: resolve(dependencies: target.dependencies, in: manifest),
            localPackageURL: localPackageURL,
            packageID: PackageID(packageKind: manifest.packageKind, packageIdentity: dependencyPackage.identity),
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

        let resolvedModuleType = moduleTypeResolver.resolve(
            target: target,
            dependencyPackage: dependencyPackage
        )

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

    private func shouldBuild(_ target: Target.TargetKind) -> Bool {
        target == .regular || target == .binary
    }
}
