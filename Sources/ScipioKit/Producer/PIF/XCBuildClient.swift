import Foundation
import Basics
import PackageGraph
import PackageModel

struct XCBuildClient {
    private let buildOptions: BuildOptions
    private let buildProduct: BuildProduct
    private let configuration: BuildConfiguration
    private let packageLocator: any PackageLocator
    private let fileSystem: any FileSystem
    private let executor: any Executor

    init(
        buildProduct: BuildProduct,
        buildOptions: BuildOptions,
        configuration: BuildConfiguration,
        packageLocator: some PackageLocator,
        fileSystem: any FileSystem = localFileSystem,
        executor: some Executor = ProcessExecutor(decoder: StandardOutputDecoder())
    ) {
        self.buildProduct = buildProduct
        self.buildOptions = buildOptions
        self.configuration = configuration
        self.packageLocator = packageLocator
        self.fileSystem = fileSystem
        self.executor = executor
    }

    private func fetchXCBuildPath() async throws -> TSCAbsolutePath {
        let developerDirPath = try await fetchDeveloperDirPath()
        let relativePath = try TSCRelativePath(validating: "../SharedFrameworks/XCBuild.framework/Versions/A/Support/xcbuild")
        return developerDirPath.appending(relativePath)
    }

    private func fetchDeveloperDirPath() async throws -> TSCAbsolutePath {
        let result = try await executor.execute(
            "/usr/bin/xcrun",
            "xcode-select",
            "-p"
        )
        return try TSCAbsolutePath(validating: try result.unwrapOutput())
    }

    private var productTargetName: String {
        let productName = buildProduct.target.name
        return "\(productName)_\(String(productName.hash, radix: 16, uppercase: true))_PackageProduct"
    }

    func buildFramework(
        sdk: SDK,
        pifPath: TSCAbsolutePath,
        buildParametersPath: TSCAbsolutePath
    ) async throws -> URL {
        let xcbuildPath = try await fetchXCBuildPath()

        let executor = XCBuildExecutor(xcbuildPath: xcbuildPath)
        try await executor.build(
            pifPath: pifPath,
            configuration: configuration,
            derivedDataPath: packageLocator.derivedDataPath,
            buildParametersPath: buildParametersPath,
            target: buildProduct.target
        )

        let frameworkBundlePath = try assembleFramework(sdk: sdk)
        return frameworkBundlePath
    }

    /// Assemble framework from build artifacts
    /// - Parameter sdk: SDK
    /// - Returns: Path to assembled framework bundle
    private func assembleFramework(sdk: SDK) throws -> URL {
        let frameworkComponentsCollector = FrameworkComponentsCollector(
            buildProduct: buildProduct,
            sdk: sdk,
            buildOptions: buildOptions,
            packageLocator: packageLocator,
            fileSystem: fileSystem
        )

        let components = try frameworkComponentsCollector.collectComponents(sdk: sdk)

        let frameworkOutputDir = packageLocator.assembledFrameworksDirectory(
            buildConfiguration: buildOptions.buildConfiguration,
            sdk: sdk
        )

        let assembler = FrameworkBundleAssembler(
            frameworkComponents: components,
            keepPublicHeadersStructure: buildOptions.keepPublicHeadersStructure,
            outputDirectory: frameworkOutputDir,
            fileSystem: fileSystem
        )

        return try assembler.assemble()
    }

    private func assembledFrameworkPath(target: ScipioResolvedModule, of sdk: SDK) throws -> TSCAbsolutePath {
        let assembledFrameworkDir = packageLocator.assembledFrameworksDirectory(
            buildConfiguration: buildOptions.buildConfiguration,
            sdk: sdk
        )
        return assembledFrameworkDir
            .appending(component: "\(buildProduct.target.c99name).framework")
    }

    func createXCFramework(
        sdks: Set<SDK>,
        debugSymbols: [SDK: [TSCAbsolutePath]]?,
        outputPath: TSCAbsolutePath
    ) async throws {
        let xcbuildPath = try await fetchXCBuildPath()

        let additionalArguments = try buildCreateXCFrameworkArguments(
            sdks: sdks,
            debugSymbols: debugSymbols,
            outputPath: outputPath
        )

        let arguments: [String] = [
            xcbuildPath.pathString,
            "createXCFramework",
        ]
        + additionalArguments
        try await executor.execute(arguments)
    }

    private func buildCreateXCFrameworkArguments(
        sdks: Set<SDK>,
        debugSymbols: [SDK: [TSCAbsolutePath]]?,
        outputPath: TSCAbsolutePath
    ) throws -> [String] {
        let frameworksWithDebugSymbolArguments: [String] = try sdks.reduce([]) { arguments, sdk in
            let path = try assembledFrameworkPath(target: buildProduct.target, of: sdk)
            var result = arguments + ["-framework", path.pathString]
            if let debugSymbols, let paths = debugSymbols[sdk] {
                paths.forEach { path in
                    result += ["-debug-symbols", path.pathString]
                }
            }
            return result
        }

        let outputPathArguments: [String] = ["-output", outputPath.pathString]

        // Default behavior, this command requires swiftinterface. If they don't exist, `-allow-internal-distribution` must be required.
        let additionalFlags = buildOptions.enableLibraryEvolution ? [] : ["-allow-internal-distribution"]
        return frameworksWithDebugSymbolArguments + outputPathArguments + additionalFlags
    }
}

private struct XCBuildOutputDecoder: ErrorDecoder {
    private let jsonDecoder = JSONDecoder()

    func decode(_ result: ExecutorResult) throws -> String? {
        let lines = try result.unwrapOutput().split(separator: "\n")
            .map(String.init)
        return lines.compactMap { line -> String? in
            if let info = try? jsonDecoder.decode(XCBuildErrorInfo.self, from: line), !info.isIgnored {
                return info.message ?? info.data
            }
            return nil
        }
        .compactMap { $0 }
        .joined(separator: "\n")
    }
}

private let ignoredKind = ["didUpdateProgress"]

private struct XCBuildErrorInfo: Decodable {
    var kind: String?
    var result: String?
    var error: String?
    var message: String?
    var data: String?

    fileprivate var isIgnored: Bool {
        if let kind {
            return ignoredKind.contains(kind)
        }
        return false
    }
}
