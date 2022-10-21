import Foundation
import TSCBasic

struct Resolver<E: Executor> {
    private let package: Package
    private let executor: E
    private let fileSystem: any ScipioKit.FileSystem

    init(package: Package, executor: E = ProcessExecutor(), fileSystem: any ScipioKit.FileSystem = ScipioKit.localFileSystem) {
        self.package = package
        self.executor = executor
        self.fileSystem = fileSystem
    }

    func resolve() async throws {
        logger.info("🔁 Resolving Dependencies...")

        fileSystem.changeCurrentWorkingDirectory(to: package.packageDirectory.asURL)
        try await executor.execute("/usr/bin/xcrun", "swift", "package", "resolve")
    }
}
