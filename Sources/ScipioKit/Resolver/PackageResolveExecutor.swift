import Foundation
import ScipioKitCore

extension PackageResolver {
    struct PackageResolveExecutor: @unchecked Sendable {
        private let executor: any Executor
        private let fileSystem: any FileSystem
        private let jsonDecoder = JSONDecoder()

        init(fileSystem: some FileSystem, executor: some Executor) {
            self.fileSystem = fileSystem
            self.executor = executor
        }

        func execute(packageDirectory: URL) async throws -> PackageResolved? {
            let commands = [
                "/usr/bin/xcrun",
                "swift",
                "package",
                "resolve",
                "--package-path",
                packageDirectory.path(percentEncoded: false),
            ]

            try await executor.execute(commands)

            let packageResolvedPath = packageDirectory.appending(component: "Package.resolved")

            guard fileSystem.exists(packageResolvedPath) else {
                return nil
            }

            let packageResolvedData = try fileSystem.readFileContents(packageResolvedPath)
            let packageResolved = try jsonDecoder.decode(PackageResolved.self, from: packageResolvedData)

            return packageResolved
        }

        enum Error: Swift.Error {
            case cannotReadPackageResolvedFile
        }
    }
}
