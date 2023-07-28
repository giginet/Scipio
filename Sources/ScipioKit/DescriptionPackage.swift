import Foundation
import Workspace
import TSCBasic
import PackageModel
import PackageLoading
import PackageGraph
import Basics

struct DescriptionPackage {
    let mode: Runner.Mode
    let packageDirectory: AbsolutePath
    private let toolchain: UserToolchain
    let workspace: Workspace
    let graph: PackageGraph
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

    var buildDirectory: AbsolutePath {
        packageDirectory.appending(component: ".build")
    }

    var workspaceDirectory: AbsolutePath {
        buildDirectory.appending(component: "scipio")
    }

    var supportedSDKs: Set<SDK> {
        Set(manifest.platforms.map(\.platformName).compactMap(SDK.init(platformName:)))
    }

    var derivedDataPath: AbsolutePath {
        workspaceDirectory.appending(component: "DerivedData")
    }

    func generatedModuleMapPath(of target: ResolvedTarget, sdk: SDK) throws -> AbsolutePath {
        let relativePath = try RelativePath(validating: "GeneratedModuleMaps/\(sdk.settingValue)")
        return workspaceDirectory
            .appending(relativePath)
            .appending(component: target.modulemapName)
    }

    // MARK: Initializer

    private static func makeWorkspace(toolchain: UserToolchain, packagePath: AbsolutePath) throws -> Workspace {
        var workspaceConfiguration: WorkspaceConfiguration = .default
        // override default configuration to treat XIB files
        workspaceConfiguration.additionalFileRules = FileRuleDescription.xcbuildFileTypes

        let fileSystem = TSCBasic.localFileSystem
        let workspace = try Workspace(
            fileSystem: fileSystem,
            location: Workspace.Location(forRootPackage: packagePath, fileSystem: fileSystem),
            configuration: workspaceConfiguration,
            customHostToolchain: toolchain
        )
        return workspace
    }

    init(packageDirectory: AbsolutePath, mode: Runner.Mode) throws {
        self.packageDirectory = packageDirectory
        self.mode = mode

        let toolchain = try UserToolchain(destination: try .hostDestination())
        self.toolchain = toolchain

        let workspace = try Self.makeWorkspace(toolchain: toolchain, packagePath: packageDirectory)
        let scope = observabilitySystem.topScope
        self.graph = try workspace.loadPackageGraph(
            rootInput: PackageGraphRootInput(packages: [packageDirectory]),
            // This option is same with resolver option `--disable-automatic-resolution`
            // Never update Package.resolved of the package
            forceResolvedVersions: true,
            observabilityScope: scope
        )
        self.manifest = try tsc_await {
            workspace.loadRootManifest(
                at: packageDirectory,
                observabilityScope: scope,
                completion: $0
            )
        }
        self.workspace = workspace
    }
}

extension DescriptionPackage {
    func resolveBuildProducts() throws -> [BuildProduct] {
        let targetsToBuild = try targetsToBuild()
        var products = try targetsToBuild.flatMap(resolveBuildProduct(from:))

        let productMap: [String: BuildProduct] = Dictionary(products.map { ($0.target.name, $0) }) { $1 }
        func resolvedTargetToBuildProduct(_ target: ResolvedTarget) -> BuildProduct {
            productMap[target.name]!
        }

        do {
            products = try topologicalSort(products) { (product) in
                return product.target.dependencies.flatMap { (dependency) in
                    switch dependency {
                    case .target(let target, conditions: _):
                        return [resolvedTargetToBuildProduct(target)]
                    case .product(let product, conditions: _):
                        return product.targets.map(resolvedTargetToBuildProduct)
                    }
                }
            }
        } catch {
            switch error {
            case GraphError.unexpectedCycle: throw Error.cycleDetected
            default: throw error
            }
        }

        return products.reversed()
    }

    private func targetsToBuild() throws -> Set<ResolvedTarget> {
        switch mode {
        case .createPackage:
            // In create mode, all products should be built
            // In future update, users will be enable to specify products want to build
            let rootPackage = try fetchRootPackage()
            let productsToBuild = rootPackage.products
            return Set(productsToBuild.flatMap(\.targets))
        case .prepareDependencies:
            // In prepare mode, all targets should be built
            // In future update, users will be enable to specify targets want to build
            return Set(try fetchRootPackage().targets)
        }
    }

    private func fetchRootPackage() throws -> ResolvedPackage {
        guard let rootPackage = graph.rootPackages.first else {
            throw Error.packageNotDefined
        }
        return rootPackage
    }

    private func resolveBuildProduct(from rootTarget: ResolvedTarget) throws -> Set<BuildProduct> {
        let dependencyProducts = Set(try rootTarget.recursiveTargetDependencies().flatMap(buildProducts(from:)))

        switch mode {
        case .createPackage:
            // In create mode, rootTarget should be built
            let rootTargetProducts = try buildProducts(from: rootTarget)
            return rootTargetProducts.union(dependencyProducts)
        case .prepareDependencies:
            // In prepare mode, rootTarget is just a container. So it should be skipped.
            return dependencyProducts
        }
    }

    private func buildProducts(from target: ResolvedTarget) throws -> Set<BuildProduct> {
        guard let package = graph.package(for: target) else {
            return []
        }

        let rootTargetProduct = BuildProduct(package: package, target: target)
        let dependencyProducts = try target.recursiveDependencies().compactMap(\.target).flatMap(buildProducts(from:))
        return Set([rootTargetProduct] + dependencyProducts)
    }
}

struct BuildProduct: Hashable {
    var package: ResolvedPackage
    var target: ResolvedTarget

    var frameworkName: String {
        "\(target.name.packageNamed()).xcframework"
    }

    var binaryTarget: BinaryTarget? {
        target.underlyingTarget as? BinaryTarget
    }
}
