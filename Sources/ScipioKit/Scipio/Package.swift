import Foundation
import Workspace
import TSCBasic
import PackageModel
import PackageLoading
import PackageGraph
import Basics

struct Package {
    let packageDirectory: AbsolutePath
    let toolchain: UserToolchain
    let workspace: Workspace
    let graph: PackageGraph
    let manifest: Manifest

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

    init(packageDirectory: URL) throws {
        let root = AbsolutePath(packageDirectory.path)
        self.packageDirectory = root

        self.toolchain = try UserToolchain(destination: try .hostDestination())

        let resources = ToolchainConfiguration(swiftCompilerPath: toolchain.swiftCompilerPath)
        let loader = ManifestLoader(toolchain: resources)
        let workspace = try Workspace(forRootPackage: root, customManifestLoader: loader)

        self.graph = try workspace.loadPackageGraph(rootPath: root, observabilityScope: observabilitySystem.topScope)
        let scope = observabilitySystem.topScope
        self.manifest = try tsc_await {
            workspace.loadRootManifest(
                at: root,
                observabilityScope: scope,
                completion: $0
            )
        }
        self.workspace = workspace
    }
}
