import Foundation
import Basics
import PackageManifestKit

struct DescriptionPackage: PackageLocator {
    let mode: Runner.Mode
    let packageDirectory: TSCAbsolutePath
    let graph: ModulesGraph
    let manifest: PackageManifestKit.Manifest
    let jsonDecoder = JSONDecoder()

    enum Error: LocalizedError {
        case packageNotDefined
        case cycleDetected

        var errorDescription: String? {
            switch self {
            case .packageNotDefined:
                return "Any packages are not defined in this manifest"
            case .cycleDetected:
                return "A cycle has been detected in the dependencies of the targets"
            }
        }
    }

    // MARK: Properties

    var name: String {
        manifest.name
    }

    var supportedSDKs: Set<SDK> {
        Set(manifest.platforms?.map(\.platformName).compactMap(SDK.init(platformName:)) ?? [])
    }

    private static func makeManifest(
        packageDirectory: TSCAbsolutePath,
        jsonDecoder: JSONDecoder,
        executor: some Executor
    ) async throws -> PackageManifestKit.Manifest {
        let commands = [
            "/usr/bin/xcrun",
            "swift",
            "package",
            "dump-package",
            "--package-path",
            packageDirectory.pathString,
        ]

        let manifestString = try await executor.execute(commands).unwrapOutput()
        let manifest = try jsonDecoder.decode(PackageManifestKit.Manifest.self, from: manifestString)

        return manifest
    }

    /// Make DescriptionPackage from a passed package directory
    /// - Parameter packageDirectory: A path for the Swift package to build
    /// - Parameter mode: A Scipio running mode
    /// - Parameter onlyUseVersionsFromResolvedFile: A boolean value if true disabling force updating of Package.resolved.
    /// Then, use package versions only from existing Package.resolved.
    ///   If it is `true`, Package.resolved never be updated.
    ///   Instead, the resolving will fail if the Package.resolved is mis-matched with the workspace.
    init(
        packageDirectory: TSCAbsolutePath,
        mode: Runner.Mode,
        onlyUseVersionsFromResolvedFile: Bool,
        toolchainEnvironment: ToolchainEnvironment? = nil,
        executor: some Executor = ProcessExecutor(decoder: StandardOutputDecoder())
    ) async throws {
        self.packageDirectory = packageDirectory
        self.mode = mode

        self.manifest = try await ScipioKit.ManifestLoader(executor: executor).loadManifest(for: packageDirectory.asURL)

        self.graph = try await PackageResolver(
            packageDirectory: packageDirectory.asURL,
            rootManifest: self.manifest,
            fileSystem: Basics.localFileSystem
        ).resolve()
    }
}

extension DescriptionPackage {
    func resolveBuildProductDependencyGraph() throws -> DependencyGraph<BuildProduct> {
        let resolver = BuildProductsResolver(descriptionPackage: self)
        return try resolver.resolveBuildProductDependencyGraph()
    }
}

struct BuildProduct: Hashable, Sendable {
    var package: ResolvedPackage
    var target: ResolvedModule

    var frameworkName: String {
        "\(target.name.packageNamed()).xcframework"
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.target.name == rhs.target.name &&
        lhs.package.id == rhs.package.id
    }

    func hash(into hasher: inout Hasher) {
        // Important: Relevant for swift-6.0+ toolchain versions. For the versions below
        // this change has no effect as SwiftPM provides its own proper `Hashable`
        // implementations for both `ResolvedPackage` and `ResolvedTarget`.
        //
        // We cannot directly use `ResolvedModule.id` here as `id` also includes `BuildTriple`.
        // The reason for this is that `ResolvedModule.buildTriple` is parent-dependent; more
        // specifically, the same `ResolvedModule` will have a different build triple depending
        // on whether it is in a root or dependency position.
        // For more context, see `ResolvedModule.updateBuildTriplesOfDependencies`.
        //
        // At the same time, build triples remain irrelevant for the `Scipio` use case where the
        // build product must be the same regardless of the triple. Meanwhile, the target name and
        // package identity remain relevant and unambiguously identify the build product.
        hasher.combine(target.name)
        hasher.combine(package.id)
    }
}

private final class BuildProductsResolver {
    private var buildProductsCache: [BuildProduct: Set<BuildProduct>] = [:]
    let descriptionPackage: DescriptionPackage

    init(descriptionPackage: DescriptionPackage) {
        self.descriptionPackage = descriptionPackage
    }

    func resolveBuildProductDependencyGraph() throws -> DependencyGraph<BuildProduct> {
        let targetsToBuild = try targetsToBuild()
        let products = try targetsToBuild.flatMap(resolveBuildProduct(from:))

        return try DependencyGraph<BuildProduct>.resolve(
            Set(products),
            id: \.target.name,
            childIDs: { $0.target.dependencies.flatMap(\.moduleNames) }
        )
    }

    private func targetsToBuild() throws -> [ResolvedModule] {
        switch descriptionPackage.mode {
        case .createPackage:
            // In create mode, all products should be built
            // In future update, users will be enable to specify products want to build
            let rootPackage = descriptionPackage.graph.rootPackage
            let productNamesToBuild = rootPackage.manifest.products.map { $0.name }
            let productsToBuild = rootPackage.products.filter { productNamesToBuild.contains($0.name) }
            return productsToBuild.flatMap(\.modules)
        case .prepareDependencies:
            // In prepare mode, all targets should be built
            // In future update, users will be enable to specify targets want to build
            return Array(descriptionPackage.graph.rootPackage.targets)
        }
    }

    private func resolveBuildProduct(from rootTarget: ResolvedModule) throws -> Set<BuildProduct> {
        let dependencyProducts = Set(try rootTarget.recursiveModuleDependencies()
            .flatMap(buildProducts(from:)))

        switch descriptionPackage.mode {
        case .createPackage:
            // In create mode, rootTarget should be built
            let rootTargetProducts = try buildProducts(from: rootTarget)
            return rootTargetProducts.union(dependencyProducts)
        case .prepareDependencies:
            // In prepare mode, rootTarget is just a container. So it should be skipped.
            return dependencyProducts
        }
    }

    private func buildProducts(from target: ResolvedModule) throws -> Set<BuildProduct> {
        guard let package = descriptionPackage.graph.package(for: target) else {
            return []
        }

        let rootTargetProduct = BuildProduct(package: package, target: target)

        if let buildProducts = buildProductsCache[rootTargetProduct] {
            return buildProducts
        }

        let dependencyProducts = try target.recursiveDependencies().compactMap(\.module).flatMap(buildProducts(from:))

        let buildProducts = Set([rootTargetProduct] + dependencyProducts)
        buildProductsCache.updateValue(buildProducts, forKey: rootTargetProduct)

        return buildProducts
    }
}
