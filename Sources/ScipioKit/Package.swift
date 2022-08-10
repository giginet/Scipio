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

    init(packageDirectory: AbsolutePath) throws {
        self.packageDirectory = packageDirectory

        self.toolchain = try UserToolchain(destination: try .hostDestination())

#if swift(>=5.7)
        let loader = ManifestLoader(toolchain: toolchain)
#else // for Swift 5.6
        let resources = ToolchainConfiguration(swiftCompilerPath: toolchain.swiftCompilerPath)
        let loader = ManifestLoader(toolchain: resources)
#endif
        let workspace = try Workspace(forRootPackage: packageDirectory, customManifestLoader: loader)

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
