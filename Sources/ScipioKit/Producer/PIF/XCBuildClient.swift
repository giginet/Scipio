import Foundation
import TSCBasic

struct XCBuildClient {
    private let executor: any Executor

    init(executor: any Executor) {
        self.executor = executor
    }

    enum Target {
        case allIncludingTests
        case allExcludingTests
        case target(String)
        case product(String)

        var argumentValue: String {
            switch self {
            case .allExcludingTests: return "AllExcludingTests"
            case .allIncludingTests: return "AllIncludingTests"
            case .target(let targetName): return targetName
            case .product(let productName):
                return "\(productName)_\(String(productName.hash, radix: 16, uppercase: true))_PackageProduct"
            }
        }
    }

    private func fetchXCBuildPath() async throws -> AbsolutePath {
        let developerDirPath = try await fetchDeveloperDirPath()
        let relativePath = try RelativePath(validating: "../SharedFrameworks/XCBuild.framework/Versions/A/Support/xcbuild")
        return developerDirPath.appending(relativePath)
    }

    private func fetchDeveloperDirPath() async throws -> AbsolutePath {
        let result = try await executor.execute(
            "/usr/bin/xcrun",
            "xcode-select",
            "-p"
        )
        return try AbsolutePath(validating: try result.unwrapOutput())
    }

    func buildFramework(
        pifPath: AbsolutePath,
        buildParametersPath: AbsolutePath,
        configuration: BuildConfiguration,
        target: Target
    ) async throws {
        let xcbuildPath = try await fetchXCBuildPath()
        try await executor.execute(
            xcbuildPath.pathString,
            "build",
            pifPath.pathString,
            "--configuration",
            configuration.settingsValue,
            "--derivedDataPath",
            "",
            "--buildParametersFile",
            buildParametersPath.pathString,
            "--target",
            target.argumentValue
        )
    }
}
