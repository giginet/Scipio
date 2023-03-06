import Foundation
import Workspace
import TSCBasic
import PackageModel
import PackageLoading
import PackageGraph
import Basics
import OrderedCollections

struct DescriptionPackage {
    let mode: Runner.Mode
    let packageDirectory: AbsolutePath
    private let toolchain: UserToolchain
    let workspace: Workspace
    let graph: PackageGraph
    let manifest: Manifest

    enum Error: LocalizedError {
        case packageNotDefined

        var errorDescription: String? {
            switch self {
            case .packageNotDefined:
                return "Any packages are not defined in this manifest"
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

    var projectPath: AbsolutePath {
        buildDirectory.appending(component: "\(name).xcodeproj")
    }

    var supportedSDKs: OrderedCollections.OrderedSet<SDK> {
        OrderedSet(manifest.platforms.map(\.platformName).compactMap(SDK.init(platformName:)))
    }

    var derivedDataPath: AbsolutePath {
        workspaceDirectory.appending(component: "DerivedData")
    }

    func derivedDataPath(for target: ResolvedTarget) -> AbsolutePath {
        derivedDataPath
            .appending(components: self.name)
    }

    // MARK: Initializer

    private static func makeWorkspace(packagePath: AbsolutePath) throws -> Workspace {
        var workspaceConfiguration: WorkspaceConfiguration = .default
        // override default configuration to treat XIB files
        workspaceConfiguration.additionalFileRules = FileRuleDescription.xcbuildFileTypes

        let fileSystem = TSCBasic.localFileSystem
        let workspace = try Workspace(
            fileSystem: fileSystem,
            location: Workspace.Location(forRootPackage: packagePath, fileSystem: fileSystem),
            configuration: workspaceConfiguration
        )
        return workspace
    }

    init(packageDirectory: AbsolutePath, mode: Runner.Mode) throws {
        self.packageDirectory = packageDirectory
        self.mode = mode

        self.toolchain = try UserToolchain(destination: try .hostDestination())

        let workspace = try Self.makeWorkspace(packagePath: packageDirectory)
        self.graph = try workspace.loadPackageGraph(rootPath: packageDirectory, observabilityScope: observabilitySystem.topScope)
        let scope = observabilitySystem.topScope
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
    func resolveBuildProducts() throws -> Set<BuildProduct> {
        let targetsToBuild = try targetsToBuild()
        return Set(try targetsToBuild.flatMap(resolveBuildProduct(from:)))
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
