import Foundation
import Workspace
import struct TSCBasic.AbsolutePath
import func TSCBasic.tsc_await
import PackageModel
import PackageLoading
import PackageGraph
import Basics

struct Package {
    let packageDirectory: URL
    let toolchain: UserToolchain
    let workspace: Workspace
    let graph: PackageGraph
    let manifest: Manifest

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

    var supportedSDKs: [SDK] {
        manifest.platforms.map(\.platformName).compactMap(SDK.init(platformName:))
    }

    init(packageDirectory: URL) throws {
        self.packageDirectory = packageDirectory
        let absolutePath = try AbsolutePath(validating: packageDirectory.path)

        self.toolchain = try UserToolchain(destination: try .hostDestination())

#if swift(>=5.7)
        let loader = ManifestLoader(toolchain: toolchain)
#else // for Swift 5.6
        let resources = ToolchainConfiguration(swiftCompilerPath: toolchain.swiftCompilerPath)
        let loader = ManifestLoader(toolchain: resources)
#endif
        let workspace = try Workspace(forRootPackage: absolutePath, customManifestLoader: loader)

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
}

struct BuildProduct {
    var package: ResolvedPackage
    var target: ResolvedTarget

    var frameworkName: String {
        "\(target.name.packageNamed()).xcframework"
    }

    var isBinaryTarget: Bool {
        target.underlyingTarget is BinaryTarget
    }
}
