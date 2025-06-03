import Foundation

extension PackageResolver {
    /// Parses the output of `swift package show-dependencies`.
    struct ShowDependenciesParser: @unchecked Sendable {
        private struct ShowDependenciesResponse: Decodable {
            var identity: String
            var name: String
            var url: String
            var version: String
            var path: String
            var dependencies: [ShowDependenciesResponse]?
        }

        struct DependencyPackages {
            var dependencyPackagesByID: [DependencyPackage.ID: DependencyPackage]
            var dependencyPackagesByName: [String: DependencyPackage]
        }

        let executor: any Executor
        let jsonDecoder = JSONDecoder()

        init(executor: some Executor) {
            self.executor = executor
        }

        func parse(packageDirectory: URL) async throws -> DependencyPackages {
            let commands = [
                "/usr/bin/xcrun",
                "swift",
                "package",
                "show-dependencies",
                "--package-path",
                packageDirectory.path,
                "--format",
                "json",
            ]

            let dependencyString = try await executor.execute(commands).unwrapOutput()
            let dependency = try jsonDecoder.decode(ShowDependenciesResponse.self, from: dependencyString)
            return flattenPackages(dependency)
        }

        private func flattenPackages(_ package: ShowDependenciesResponse) -> DependencyPackages {
            var dependencyPackagesByID: [DependencyPackage.ID: DependencyPackage] = [:]
            var dependencyPackagesByName: [String: DependencyPackage] = [:]

            func traverse(_ package: ShowDependenciesResponse) {
                let dependencyPackage = DependencyPackage(
                    identity: package.identity,
                    name: package.name,
                    url: package.url,
                    version: package.version,
                    path: package.path
                )
                dependencyPackagesByID[dependencyPackage.id] = dependencyPackage
                dependencyPackagesByName[dependencyPackage.name] = dependencyPackage
                package.dependencies?.forEach { traverse($0) }
            }

            traverse(package)

            return DependencyPackages(
                dependencyPackagesByID: dependencyPackagesByID,
                dependencyPackagesByName: dependencyPackagesByName
            )
        }
    }
}
