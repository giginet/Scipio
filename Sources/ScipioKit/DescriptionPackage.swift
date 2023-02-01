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
    let packageDirectory: URL
    private let toolchain: UserToolchain
    let workspace: Workspace
    let graph: PackageGraph
    let manifest: Manifest

    enum Error: LocalizedError {
        case packageNotDefined
    }

    var name: String {
        manifest.displayName
    }

    var buildDirectory: URL {
        packageDirectory.appendingPathComponent(".build")
    }

    var workspaceDirectory: URL {
        buildDirectory.appendingPathComponent("scipio")
    }

    var projectPath: URL {
        buildDirectory.appendingPathComponent("\(name).xcodeproj")
    }

    var supportedSDKs: OrderedCollections.OrderedSet<SDK> {
        OrderedSet(manifest.platforms.map(\.platformName).compactMap(SDK.init(platformName:)))
    }

    var derivedDataPath: URL {
        workspaceDirectory.appendingPathComponent("DerivedData")
    }

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

    init(packageDirectory: URL, mode: Runner.Mode) throws {
        self.packageDirectory = packageDirectory
        self.mode = mode
        let absolutePath = try AbsolutePath(validating: packageDirectory.path)

        self.toolchain = try UserToolchain(destination: try .hostDestination())

        let workspace = try Self.makeWorkspace(packagePath: try AbsolutePath(validating: packageDirectory.path))
        self.graph = try workspace.loadPackageGraph(rootPath: absolutePath, observabilityScope: observabilitySystem.topScope)
        let scope = observabilitySystem.topScope
        self.manifest = try tsc_await {
            workspace.loadRootManifest(
                at: absolutePath,
                observabilityScope: scope,
                completion: $0
            )
        }
        self.workspace = workspace
    }

    func recursiveBuildProducts() throws -> [BuildProduct] {
        switch  mode {
        case .createPackage:
            return graph.rootPackages
                .flatMap { package in
                    package.targets
                        .map { BuildProduct(package: package, target: $0) }
                }
        case .prepareDependencies:
            guard let descriptionTarget = graph.rootPackages.first?.targets.first else {
                return []
            }
            return try descriptionTarget.recursiveDependencies().compactMap { dependency -> BuildProduct? in
                guard let target = dependency.target else {
                    return nil
                }
                guard let package = graph.package(for: target) else {
                    return nil
                }
                return BuildProduct(package: package, target: target)
            }
        }
    }
}

struct BuildProduct {
    var package: ResolvedPackage
    var target: ResolvedTarget

    var frameworkName: String {
        "\(target.name.packageNamed()).xcframework"
    }

    var binaryTarget: BinaryTarget? {
        target.underlyingTarget as? BinaryTarget
    }
}
