import TSCBasic
import PackageGraph

struct XcodeBuildClient<E: Executor> {
    let executor: E

    func createXCFramework(context: CreateXCFrameworkCommand.Context, outputDir: AbsolutePath) async throws {
        try await executor.execute(CreateXCFrameworkCommand(context: context, outputDir: outputDir))
    }

    func archive(package: Package, target: ResolvedTarget, buildConfiguration: BuildConfiguration, sdk: SDK) async throws {
        try await executor.execute(ArchiveCommand(context: .init(
            package: package,
            target: target,
            buildConfiguration: buildConfiguration,
            sdk: sdk
        )))
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
