import Foundation
import PackageGraph
import PackageLoading
import XcodeProj
import TSCBasic

private struct Resource: Hashable {
    var path: URL
    var localization: String?
    var isDir: Bool
}

struct ResourceBundleTargetGenerator {
    init(package: ResolvedPackage, target: ResolvedTarget, fileSystem: FileSystem = localFileSystem) {
        self.package = package
        self.target = target
        self.fileSystem = fileSystem
    }

    private func makeTargetSourceBuilder() -> TargetSourcesBuilder {
        TargetSourcesBuilder(
            packageIdentity: package.identity,
            packageKind: package.manifest.packageKind,
            packagePath: package.path,
            target: package.manifest.targetMap[target.name]!, // TODO
            path: package.path,
            defaultLocalization: package.manifest.defaultLocalization,
            additionalFileRules: [], // TODO
            toolsVersion: package.manifest.toolsVersion,
            fileSystem: TSCBasic.localFileSystem,
            observabilityScope: observabilitySystem.topScope)
    }

    private let package: ResolvedPackage
    private let target: ResolvedTarget
    private let fileSystem: FileSystem

    private var bundleTargetName: String {
        "\(target.c99name)-Resources"
    }

    func generate() throws -> PBXTarget {
        let builder = makeTargetSourceBuilder()
        let (_, resouces, _, _, _) = try builder.run()

        for resouce in resouces {

        }

        return PBXTarget(name: bundleTargetName, productType: .bundle)
    }

    // https://developer.apple.com/documentation/xcode/bundling-resources-with-a-swift-package
    private func detectWellKnownResources(for path: URL) -> Bool {
        return false
    }
}
