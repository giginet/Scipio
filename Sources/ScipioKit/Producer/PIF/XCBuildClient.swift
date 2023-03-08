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
    private let buildExecutor: any Executor

    init(
        package: DescriptionPackage,
        buildProduct: BuildProduct,
        buildOptions: BuildOptions,
        configuration: BuildConfiguration,
        fileSystem: any FileSystem = localFileSystem,
        executor: any Executor = ProcessExecutor(decoder: StandardOutputDecoder()),
        xcBuildExecutor: any Executor = ProcessExecutor(decoder: XCBuildOutputDecoder())
    ) {
        self.descriptionPackage = package
        self.buildProduct = buildProduct
        self.buildOptions = buildOptions
        self.configuration = configuration
        self.fileSystem = fileSystem
        self.executor = executor
        self.buildExecutor = xcBuildExecutor
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

        let modulemapGenerator = ModuleMapGenerator(
            descriptionPackage: descriptionPackage,
            sdk: sdk,
            configuration: configuration,
            resolvedTarget: buildProduct.target,
            fileSystem: fileSystem
        )
        try modulemapGenerator.generate()

        let xcbuildPath = try await fetchXCBuildPath()
        try await buildExecutor.execute(
            xcbuildPath.pathString,
            "build",
            pifPath.pathString,
            "--configuration",
            configuration.settingsValue,
            "--derivedDataPath",
            descriptionPackage.derivedDataPath.pathString,
            "--buildParametersFile",
            buildParametersPath.pathString,
            "--target",
            buildProduct.target.name
        )

        // Copy modulemap to outputFramework
        // xcbuild generates modulemap for each frameworks
        // However, these are not includes in Frameworks
        // So they should be copied into frameworks manually.
        try copyModulemap(for: sdk)
    }

    private func copyModulemap(for sdk: SDK) throws {
        let destinationFrameworkPath = try frameworkPath(target: buildProduct.target, of: sdk)
        let modulesDir = destinationFrameworkPath.appending(component: "Modules")
        if !fileSystem.exists(modulesDir) {
            try fileSystem.createDirectory(modulesDir)
        }

        let generatedModuleMapPath = try generatedModuleMapPath(of: buildProduct.target, sdk: sdk, workspaceDirectory: descriptionPackage.workspaceDirectory)
        if fileSystem.exists(generatedModuleMapPath) {
            try fileSystem.copy(
                from: generatedModuleMapPath,
                to: modulesDir.appending(component: "module.modulemap")
            )
        }
    }

    private func frameworkPath(target: ResolvedTarget, of sdk: SDK) throws -> AbsolutePath {
        let frameworkPath = try RelativePath(validating: "./Products/\(productDirectoryName(sdk: sdk))/PackageFrameworks")
            .appending(component: "\(buildProduct.target.c99name).framework")
        return descriptionPackage.derivedDataPath.appending(frameworkPath)
    }

    private func productDirectoryName(sdk: SDK) -> String {
        if sdk == .macOS {
            return configuration.settingsValue
        } else {
            return "\(configuration.settingsValue)-\(sdk.settingValue)"
        }
    }

    func createXCFramework(sdks: Set<SDK>, debugSymbols: [AbsolutePath]?, outputPath: AbsolutePath) async throws {
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

    private func buildCreateXCFrameworkArguments(sdks: Set<SDK>, debugSymbols: [AbsolutePath]?, outputPath: AbsolutePath) throws -> [String] {
        let frameworksArguments: [String] = try sdks.reduce([]) { arguments, sdk in
            let path = try frameworkPath(target: buildProduct.target, of: sdk)
            return arguments + ["-framework", path.pathString]
        }

        let debugSymbolsArguments: [String] = debugSymbols?.reduce(into: []) { arguments, path in
            arguments.append(contentsOf: ["-debug-symbols", path.pathString])
        } ?? []

        let outputPathArguments: [String] = ["-output", outputPath.pathString]

        // Default behavior, this command requires swiftinterface. If they don't exist, `-allow-internal-distribution` must be required.
        let additionalFlags = buildOptions.enableLibraryEvolution ? [] : ["-allow-internal-distribution"]
        return frameworksArguments + debugSymbolsArguments + outputPathArguments + additionalFlags
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

struct ModuleMapGenerator {
    struct ModuleMapResult {
        var moduleMapPath: AbsolutePath
        var isGenerated: Bool
    }

    private var descriptionPackage: DescriptionPackage
    private var sdk: SDK
    private var configuration: BuildConfiguration
    private var resolvedTarget: ResolvedTarget
    private var fileSystem: any FileSystem

    init(descriptionPackage: DescriptionPackage, sdk: SDK, configuration: BuildConfiguration, resolvedTarget: ResolvedTarget, fileSystem: any FileSystem) {
        self.descriptionPackage = descriptionPackage
        self.sdk = sdk
        self.configuration = configuration
        self.resolvedTarget = resolvedTarget
        self.fileSystem = fileSystem
    }

    private func makeModuleMapContents() -> String {
        if let clangTarget = resolvedTarget.underlyingTarget as? ClangTarget {
            switch clangTarget.moduleMapType {
            case .custom, .none:
                fatalError("Unsupported moduleMapType")
            case .umbrellaHeader(let headerPath):
                return """
                framework module \(resolvedTarget.c99name) {
                    umbrella header "\(headerPath.basename)"
                    export *
                }
                """
                    .trimmingCharacters(in: .whitespaces)
            case .umbrellaDirectory(let directoryPath):
                return """
                framework module \(resolvedTarget.c99name) {
                    umbrella "\(directoryPath.basename)"
                    export *
                }
                """
                    .trimmingCharacters(in: .whitespaces)
            }
        } else {
            // "settings[.SWIFT_OBJC_INTERFACE_HEADER_NAME]"
            let bridgingHeaderName = nil ?? "\(resolvedTarget.name)-Swift.h"
            return """
                framework module \(resolvedTarget.c99name) {
                    header "\(bridgingHeaderName)"
                    export *
                }
            """
                .trimmingCharacters(in: .whitespaces)
        }
    }

    private func generateModuleMapFile(outputPath: AbsolutePath) throws {
        let dirPath = outputPath.parentDirectory
        try fileSystem.createDirectory(dirPath, recursive: true)

        let contents = makeModuleMapContents()
        try fileSystem.writeFileContents(outputPath, string: contents)
    }

    private func constructGeneratedModuleMapPath() throws -> AbsolutePath {
        let generatedModuleMapPath = try generatedModuleMapPath(of: resolvedTarget, sdk: sdk, workspaceDirectory: descriptionPackage.workspaceDirectory)
        return generatedModuleMapPath
    }

    func generate() throws -> ModuleMapResult? {
        if let clangTarget = resolvedTarget.underlyingTarget as? ClangTarget {
            switch clangTarget.moduleMapType {
            case .custom(let moduleMapPath):
                let path = try AbsolutePath(validating: moduleMapPath.pathString)
                return .init(moduleMapPath: path, isGenerated: true)
            case .umbrellaHeader, .umbrellaDirectory:
                let path = try constructGeneratedModuleMapPath()
                try generateModuleMapFile(outputPath: path)
                return .init(moduleMapPath: path, isGenerated: true)
            case .none:
                return .none
            }
        } else {
            let path = try constructGeneratedModuleMapPath()
            try generateModuleMapFile(outputPath: path)
            return .init(moduleMapPath: path, isGenerated: true)
        }
    }
}

private func generatedModuleMapPath(of target: ResolvedTarget, sdk: SDK, workspaceDirectory: AbsolutePath) throws -> AbsolutePath {
    let relativePath = try RelativePath(validating: "GeneratedModuleMaps/\(sdk.settingValue)")
    return workspaceDirectory
        .appending(relativePath)
        .appending(component: target.modulemapName)
}
