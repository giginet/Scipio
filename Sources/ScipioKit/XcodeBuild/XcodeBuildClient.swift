import TSCBasic
import PackageGraph

struct XcodeBuildClient<E: Executor> {
    let executor: E

    func createXCFramework(
        package: Package,
        target: ResolvedTarget,
        buildConfiguration: BuildConfiguration,
        sdks: Set<SDK>,
        debugSymbolPaths: [AbsolutePath]?,
        outputDir: AbsolutePath
    ) async throws {
        try await executor.execute(CreateXCFrameworkCommand(
            package: package,
            target: target,
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

    func clean(projectPath: AbsolutePath, buildDirectory: AbsolutePath) async throws {
        try await executor.execute(CleanCommand(projectPath: projectPath, buildDirectory: buildDirectory))
    }
}

extension Executor {
    @discardableResult
    fileprivate func execute(_ command: some XcodeBuildCommand) async throws -> ExecutorResult {
        try await execute(command.buildArguments())
    }
}
