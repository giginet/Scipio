import Foundation
import TSCBasic
import PackageGraph

struct XCBuildClient {
    private let package: Package
    private let productName: String
    private let configuration: BuildConfiguration
    private let executor: any Executor

    init(package: Package, productName: String, configuration: BuildConfiguration, executor: any Executor = ProcessExecutor()) {
        self.package = package
        self.productName = productName
        self.configuration = configuration
        self.executor = executor
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

    private var productTargetName: String {
        "\(productName)_\(String(productName.hash, radix: 16, uppercase: true))_PackageProduct"
    }

    func buildFramework(
        pifPath: AbsolutePath,
        buildParametersPath: AbsolutePath
    ) async throws {
        let xcbuildPath = try await fetchXCBuildPath()
        try await executor.execute(
            xcbuildPath.pathString,
            "build",
            pifPath.pathString,
            "--configuration",
            configuration.settingsValue,
            "--derivedDataPath",
            package.derivedDataPath.path,
            "--buildParametersFile",
            buildParametersPath.pathString,
            "--target",
            productTargetName
        )
    }

    private func frameworkPath(of sdk: SDK) throws -> AbsolutePath {
        let frameworkPath = try RelativePath(validating: "./Products/\(productDirectoryName(sdk: sdk))/PackageFrameworks")
            .appending(component: "\(productName).framework")
        return try AbsolutePath(validating: package.derivedDataPath.path).appending(frameworkPath)
    }

    private func productDirectoryName(sdk: SDK) -> String {
        if sdk == .macOS {
            return configuration.settingsValue
        } else {
            return "\(configuration.settingsValue)-\(sdk.settingValue)"
        }
    }

    func createXCFramework(sdks: Set<SDK>, debugSymbols: [URL]?, outputPath: AbsolutePath) async throws {
        let xcbuildPath = try await fetchXCBuildPath()
        let arguments: [String] = [xcbuildPath.pathString, "createXCFramework"]

        let frameworksArguments: [String] = try sdks.reduce([]) { arguments, sdk in
            let path = try frameworkPath(of: sdk)
            return arguments + ["-framework", path.pathString]
        }

        let debugSymbolsArguments: [String] = debugSymbols?.reduce(into: []) { arguments, path in
            arguments.append(contentsOf: ["-debug-symbols", path.path])
        } ?? []

        let outputPathArguments: [String] = ["-output", outputPath.pathString]

        try await executor.execute(arguments + frameworksArguments + debugSymbolsArguments + outputPathArguments)
    }
}

extension Package {
    fileprivate var derivedDataPath: URL {
        workspaceDirectory.appendingPathComponent("DerivedData")
    }
}
