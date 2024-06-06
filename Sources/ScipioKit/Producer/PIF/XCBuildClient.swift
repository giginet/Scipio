import Foundation
import TSCBasic
import PackageGraph
import PackageModel

struct XCBuildClient {
    private let descriptionPackage: DescriptionPackage
    private let buildOptions: BuildOptions
    private let buildProduct: BuildProduct
    private let configuration: BuildConfiguration
    private let fileSystem: any FileSystem
    private let executor: any Executor

    init(
        package: DescriptionPackage,
        buildProduct: BuildProduct,
        buildOptions: BuildOptions,
        configuration: BuildConfiguration,
        fileSystem: any FileSystem = localFileSystem,
        executor: any Executor = ProcessExecutor(decoder: StandardOutputDecoder())
    ) {
        self.descriptionPackage = package
        self.buildProduct = buildProduct
        self.buildOptions = buildOptions
        self.configuration = configuration
        self.fileSystem = fileSystem
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
        sdk: SDK,
        pifPath: AbsolutePath,
        buildParametersPath: AbsolutePath
    ) async throws {
        let xcbuildPath = try await fetchXCBuildPath()

        let executor = XCBuildExecutor(xcbuildPath: xcbuildPath)
        try await executor.build(
            pifPath: pifPath,
            configuration: configuration,
            derivedDataPath: descriptionPackage.derivedDataPath,
            buildParametersPath: buildParametersPath,
            target: buildProduct.target
        )

        try assembleFramework(sdk: sdk)

        // Copy modulemap to built frameworks
        // xcbuild generates modulemap for each frameworks
        // However, these are not includes in Frameworks
        // So they should be copied into frameworks manually.
//        try copyModulemap(for: sdk)
    }

    private func assembleFramework(sdk: SDK) throws {
        let frameworkComponentsCollector = FrameworkComponentsCollector(
            descriptionPackage: descriptionPackage,
            buildProduct: buildProduct,
            sdk: sdk,
            buildOptions: buildOptions,
            fileSystem: fileSystem
        )

        let components = try frameworkComponentsCollector.collectComponents(sdk: sdk)

        let frameworkOutputDir = descriptionPackage.assembledFrameworksDirectory(
            buildConfiguration: buildOptions.buildConfiguration,
            sdk: sdk
        )

        let assembler = FrameworkBundleAssembler(
            frameworkComponents: components,
            outputDirectory: frameworkOutputDir,
            fileSystem: fileSystem
        )

        try assembler.assemble()
    }

    private func assembledFrameworkPath(target: ScipioResolvedTarget, of sdk: SDK) throws -> AbsolutePath {
        let assembledFrameworkDir = descriptionPackage.assembledFrameworksDirectory(
            buildConfiguration: buildOptions.buildConfiguration,
            sdk: sdk
        )
        return assembledFrameworkDir
            .appending(component: "\(buildProduct.target.c99name).framework")
    }

    func createXCFramework(sdks: Set<SDK>, debugSymbols: [SDK: [AbsolutePath]]?, outputPath: AbsolutePath) async throws {
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

    private func buildCreateXCFrameworkArguments(sdks: Set<SDK>, debugSymbols: [SDK: [AbsolutePath]]?, outputPath: AbsolutePath) throws -> [String] {
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

    func decode(_ result: any ExecutorResult) throws -> String? {
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
