import Foundation
import Workspace
import TSCBasic
import PackageModel
import PackageLoading
import PackageGraph
import Basics

struct Package {
    let toolchain: UserToolchain
    let workspace: Workspace
    let graph: PackageGraph
    let manifest: Manifest

    public init(packageDirectory: URL) throws {
        let root = AbsolutePath(packageDirectory.path)

        self.toolchain = try UserToolchain(destination: try .hostDestination())

        let resources = ToolchainConfiguration(swiftCompilerPath: toolchain.swiftCompilerPath)
        let loader = ManifestLoader(toolchain: resources)
        let workspace = try Workspace(forRootPackage: root, customManifestLoader: loader)

        let observabilitySystem = ObservabilitySystem { _, diagnostics in
            print("\(diagnostics.severity): \(diagnostics.message)")
        }

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
