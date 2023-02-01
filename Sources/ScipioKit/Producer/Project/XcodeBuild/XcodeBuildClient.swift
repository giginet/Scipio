import Foundation
import PackageGraph

struct XcodeBuildClient<E: Executor> {
    let executor: E

    func createXCFramework(
        package: Package,
        buildProduct: BuildProduct,
        buildConfiguration: BuildConfiguration,
        sdks: Set<SDK>,
        debugSymbolPaths: [URL]?,
        outputDir: URL
    ) async throws {
        try await executor.execute(CreateXCFrameworkCommand(
            package: package,
            target: buildProduct.target,
            buildConfiguration: buildConfiguration,
            sdks: sdks,
            debugSymbolPaths: debugSymbolPaths,
            outputDir: outputDir
        ))
    }

    func archive(package: Package, target: ResolvedTarget, buildConfiguration: BuildConfiguration, sdk: SDK) async throws {
        try await executor.execute(ArchiveCommand(
            package: package,
            target: target,
            buildConfiguration: buildConfiguration,
            sdk: sdk
        ))
    }

    func clean(package: Package) async throws {
        try await executor.execute(CleanCommand(package: package))
    }
}

extension Executor {
    @discardableResult
    fileprivate func execute(_ command: some XcodeBuildCommand) async throws -> ExecutorResult {
        try await execute(command.buildArguments())
    }
}
