import Foundation
import TSCBasic

struct Resolver<E: Executor> {
    private let package: Package
    private let executor: E
    private let fileSystem: any FileSystem

    init(package: Package, executor: E = ProcessExecutor(), fileSystem: any FileSystem = localFileSystem) {
        self.package = package
        self.executor = executor
        self.fileSystem = fileSystem
    }

    func resolve() async throws {
        logger.info("🔁 Resolving Dependencies...")

        try fileSystem.changeCurrentWorkingDirectory(to: package.packageDirectory.absolutePath)
        try await executor.execute("/usr/bin/xcrun", "swift", "package", "resolve")
    }
}
