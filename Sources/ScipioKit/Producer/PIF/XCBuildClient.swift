import Foundation
import TSCBasic
import PackageGraph

struct XCBuildClient {
    private let package: Package
    private let buildProduct: BuildProduct
    private let configuration: BuildConfiguration
    private let executor: any Executor

    init(package: Package, buildProduct: BuildProduct, configuration: BuildConfiguration, executor: any Executor = ProcessExecutor()) {
        self.package = package
        self.buildProduct = buildProduct
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
        let productName = buildProduct.target.name
        return "\(productName)_\(String(productName.hash, radix: 16, uppercase: true))_PackageProduct"
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
            package.derivedDataPath(for: buildProduct.target).path,
            "--buildParametersFile",
            buildParametersPath.pathString,
            "--target",
            buildProduct.target.name
        )
    }

    private func frameworkPath(target: ResolvedTarget, of sdk: SDK) throws -> AbsolutePath {
        let frameworkPath = try RelativePath(validating: "./Products/\(productDirectoryName(sdk: sdk))/PackageFrameworks")
            .appending(component: "\(buildProduct.target.c99name).framework")
        return try AbsolutePath(validating: package.derivedDataPath(for: target).path).appending(frameworkPath)
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

        let additionalArguments = try buildCreateXCFrameworkArguments(
            sdks: sdks,
            debugSymbols: debugSymbols,
            outputPath: outputPath
        )

        let arguments: [String] = [
            xcbuildPath.pathString,
            "createXCFramework"
        ]
        + additionalArguments
        try await executor.execute(arguments)
    }

    private func buildCreateXCFrameworkArguments(sdks: Set<SDK>, debugSymbols: [URL]?, outputPath: AbsolutePath) throws -> [String] {
        let frameworksArguments: [String] = try sdks.reduce([]) { arguments, sdk in
            let path = try frameworkPath(target: buildProduct.target, of: sdk)
            return arguments + ["-framework", path.pathString]
        }

        let debugSymbolsArguments: [String] = debugSymbols?.reduce(into: []) { arguments, path in
            arguments.append(contentsOf: ["-debug-symbols", path.path])
        } ?? []

        let outputPathArguments: [String] = ["-output", outputPath.pathString]

        return frameworksArguments + debugSymbolsArguments + outputPathArguments
    }
}

extension Package {
    fileprivate func derivedDataPath(for target: ResolvedTarget) -> URL {
        workspaceDirectory.appendingPathComponent("DerivedData")
            .appendingPathComponent(self.name)
            .appendingPathComponent(target.name)
    }
}
