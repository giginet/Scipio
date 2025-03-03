import Foundation
import Workspace
import Basics
import enum TSCBasic.GraphError
import func TSCBasic.topologicalSort
import Collections
import PackageModel
import PackageLoading
// We may drop this annotation in SwiftPM's future release
@preconcurrency import PackageGraph

struct DescriptionPackage: PackageLocator {
    let mode: Runner.Mode
    let packageDirectory: TSCAbsolutePath
    private let toolchain: UserToolchain
    let workspace: Workspace
    let graph: ModulesGraph
    let manifest: Manifest

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
        manifest.displayName
    }

    var supportedSDKs: Set<SDK> {
        Set(manifest.platforms.map(\.platformName).compactMap(SDK.init(platformName:)))
    }

    // MARK: Initializer

    private static func makeWorkspace(toolchain: UserToolchain, packagePath: TSCAbsolutePath) throws -> Workspace {
        var workspaceConfiguration: WorkspaceConfiguration = .default
        // override default configuration to treat XIB files
        workspaceConfiguration.additionalFileRules = FileRuleDescription.xcbuildFileTypes

        let fileSystem = Basics.localFileSystem
        let authorizationProvider = try Workspace.Configuration.Authorization.default
            .makeAuthorizationProvider(fileSystem: fileSystem, observabilityScope: makeObservabilitySystem().topScope)
        let workspace = try Workspace(
            fileSystem: fileSystem,
            location: Workspace.Location(forRootPackage: packagePath.spmAbsolutePath, fileSystem: fileSystem),
            authorizationProvider: authorizationProvider,
            configuration: workspaceConfiguration,
            customHostToolchain: toolchain
        )
        return workspace
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
        toolchainEnvironment: ToolchainEnvironment? = nil
    ) async throws {
        self.packageDirectory = packageDirectory
        self.mode = mode
        self.toolchain = try UserToolchain(
            swiftSDK: try .hostSwiftSDK(
                toolchainEnvironment?.toolchainBinPath,
                environment: toolchainEnvironment?.asSwiftPMEnvironment ?? .current
            ),
            environment: toolchainEnvironment?.asSwiftPMEnvironment ?? .current
        )

        let workspace = try Self.makeWorkspace(toolchain: toolchain, packagePath: packageDirectory)
        let scope = makeObservabilitySystem().topScope
#if compiler(>=6.1)
        self.graph = try await workspace.loadPackageGraph(
            rootInput: PackageGraphRootInput(packages: [packageDirectory.spmAbsolutePath]),
            // This option is same with resolver option `--disable-automatic-resolution`
            // Never update Package.resolved of the package
            forceResolvedVersions: onlyUseVersionsFromResolvedFile,
            observabilityScope: scope
        )
#else
        self.graph = try workspace.loadPackageGraph(
            rootInput: PackageGraphRootInput(packages: [packageDirectory.spmAbsolutePath]),
            // This option is same with resolver option `--disable-automatic-resolution`
            // Never update Package.resolved of the package
            forceResolvedVersions: onlyUseVersionsFromResolvedFile,
            observabilityScope: scope
        )
#endif
        self.manifest = try await workspace.loadRootManifest(
            at: packageDirectory.spmAbsolutePath,
            observabilityScope: scope
        )
        self.workspace = workspace
    }
}

extension DescriptionPackage {
    func resolveBuildProducts() throws -> OrderedSet<BuildProduct> {
        let resolver = BuildProductsResolver(descriptionPackage: self)
        return try resolver.resolveBuildProducts()
    }
}

struct BuildProduct: Hashable, Sendable {
    var package: ResolvedPackage
    var target: ScipioResolvedModule

    var frameworkName: String {
        "\(target.name.packageNamed()).xcframework"
    }

    var binaryTarget: ScipioBinaryModule? {
        target.underlying as? ScipioBinaryModule
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.target.name == rhs.target.name &&
        lhs.package.identity == rhs.package.identity
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
        hasher.combine(package.identity)
    }
}

private final class BuildProductsResolver {
    private var buildProductsCache: [BuildProduct: Set<BuildProduct>] = [:]
    let descriptionPackage: DescriptionPackage

    init(descriptionPackage: DescriptionPackage) {
        self.descriptionPackage = descriptionPackage
    }

    func resolveBuildProducts() throws -> OrderedSet<BuildProduct> {
        let targetsToBuild = try targetsToBuild()
        var products = try targetsToBuild.flatMap(resolveBuildProduct(from:))

        let productMap: [String: BuildProduct] = Dictionary(products.map { ($0.target.name, $0) }) { $1 }
        func resolvedTargetToBuildProduct(_ target: ScipioResolvedModule) -> BuildProduct {
            guard let product = productMap[target.name] else {
                preconditionFailure("The dependency target (\(target.name)) was not found in the build target list")
            }
            return product
        }

        do {
            products = try topologicalSort(products) { (product) in
                return product.target.dependencies.flatMap { (dependency) -> [BuildProduct] in
                    switch dependency {
                    case .module(let module, conditions: _):
                        return [resolvedTargetToBuildProduct(module)]
                    case .product(let product, conditions: _):
                        return product.modules.map(resolvedTargetToBuildProduct)
                    }
                }
            }
        } catch {
            switch error {
            case GraphError.unexpectedCycle:
                throw DescriptionPackage.Error.cycleDetected
            default:
                throw error
            }
        }

        return OrderedSet(products.reversed())
    }

    private func targetsToBuild() throws -> [ScipioResolvedModule] {
        switch descriptionPackage.mode {
        case .createPackage:
            // In create mode, all products should be built
            // In future update, users will be enable to specify products want to build
            let rootPackage = try fetchRootPackage()
            let productNamesToBuild = rootPackage.manifest.products.map { $0.name }
            let productsToBuild = rootPackage.products.filter { productNamesToBuild.contains($0.name) }
            return productsToBuild.flatMap(\.modules)
        case .prepareDependencies:
            // In prepare mode, all targets should be built
            // In future update, users will be enable to specify targets want to build
            return Array(try fetchRootPackage().modules)
        }
    }

    private func fetchRootPackage() throws -> ResolvedPackage {
        guard let rootPackage = descriptionPackage.graph.rootPackages.first else {
            throw DescriptionPackage.Error.packageNotDefined
        }
        return rootPackage
    }

    private func resolveBuildProduct(from rootTarget: ScipioResolvedModule) throws -> Set<BuildProduct> {
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

    private func buildProducts(from target: ScipioResolvedModule) throws -> Set<BuildProduct> {
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
