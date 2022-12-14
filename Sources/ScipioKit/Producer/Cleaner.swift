import Foundation

struct Cleaner<E: Executor> {
    private let rootPackage: Package
    private let xcodebuild: XcodeBuildClient<E>

    init(rootPackage: Package, executor: E = ProcessExecutor()) {
        self.rootPackage = rootPackage
        self.xcodebuild = .init(executor: executor)
    }

    func clean() async throws {
        logger.info("🗑️ Cleaning \(rootPackage.name)...")
        try await xcodebuild.clean(package: rootPackage)
    }
}
