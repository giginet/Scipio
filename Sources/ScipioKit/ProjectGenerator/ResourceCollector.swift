import Foundation
import PackageModel
import PackageGraph
import PackageLoading
import XcodeProj
import TSCBasic

struct ResourceCollector {
    init(package: ResolvedPackage, target: ResolvedTarget, fileSystem: FileSystem = localFileSystem) {
        self.package = package
        self.target = target
        self.fileSystem = fileSystem
    }

    private func makeTargetSourceBuilder() -> TargetSourcesBuilder {
        TargetSourcesBuilder(
            packageIdentity: package.identity,
            packageKind: package.manifest.packageKind,
            packagePath: package.path  ,
            target: package.manifest.targetMap[target.name]!, // TODO
            path: target.underlyingTarget.path,
            defaultLocalization: package.manifest.defaultLocalization,
            additionalFileRules: [], // TODO
            toolsVersion: package.manifest.toolsVersion,
            fileSystem: TSCBasic.localFileSystem,
            observabilityScope: observabilitySystem.topScope)
    }

    private let package: ResolvedPackage
    private let target: ResolvedTarget
    private let fileSystem: FileSystem

    func collect() throws -> [Resource] {
        let builder = makeTargetSourceBuilder()
        let (_, resources, _, _, _) = try builder.run()

        return resources
    }
}
