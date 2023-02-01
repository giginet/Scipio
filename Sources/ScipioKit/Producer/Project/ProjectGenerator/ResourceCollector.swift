import Foundation
import PackageModel
import PackageGraph
import PackageLoading
import XcodeProj
import TSCBasic

struct ResourceCollector {
    private let package: ResolvedPackage
    private let target: ResolvedTarget
    private let fileSystem: FileSystem

    enum Error: LocalizedError {
        case unableLoadingManifest(ResolvedTarget)

        var errorDescription: String? {
            switch self {
            case .unableLoadingManifest(let target):
                return "Unable to load the package manifest on \(target.name)"
            }
        }
    }

    init(package: ResolvedPackage, target: ResolvedTarget, fileSystem: FileSystem = localFileSystem) {
        self.package = package
        self.target = target
        self.fileSystem = fileSystem
    }

    private func makeTargetSourceBuilder() throws -> TargetSourcesBuilder {
        guard let targetDescription = package.manifest.targetMap[target.name] else {
            throw Error.unableLoadingManifest(target)
        }
        return TargetSourcesBuilder(
            packageIdentity: package.identity,
            packageKind: package.manifest.packageKind,
            packagePath: package.path,
            target: targetDescription,
            path: target.underlyingTarget.path,
            defaultLocalization: package.manifest.defaultLocalization,
            additionalFileRules: FileRuleDescription.xcbuildFileTypes,
            toolsVersion: package.manifest.toolsVersion,
            fileSystem: TSCBasic.localFileSystem,
            observabilityScope: observabilitySystem.topScope)
    }

    func collect() throws -> [Resource] {
        let builder = try makeTargetSourceBuilder()
        return try builder.run().resources
    }
}
