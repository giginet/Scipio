import Foundation
import Basics
import PackageModel

/// FileLists to assemble a framework bundle
struct FrameworkComponents {
    var frameworkName: String
    var frameworkPath: TSCAbsolutePath
    var binaryPath: TSCAbsolutePath
    var infoPlistPath: TSCAbsolutePath
    var swiftModulesPath: TSCAbsolutePath?
    var includeDir: TSCAbsolutePath?
    var publicHeaderPaths: Set<TSCAbsolutePath>?
    var bridgingHeaderPath: TSCAbsolutePath?
    var modulemapPath: TSCAbsolutePath?
    var resourceBundlePath: TSCAbsolutePath?
}

/// A collector to collect framework components from a DerivedData dir
struct FrameworkComponentsCollector {
    enum Error: LocalizedError {
        case infoPlistNotFound(frameworkBundlePath: TSCAbsolutePath)

        var errorDescription: String? {
            switch self {
            case .infoPlistNotFound(let frameworkBundlePath):
                return "Info.plist is not found in \(frameworkBundlePath.pathString)"
            }
        }
    }

    private let buildProduct: BuildProduct
    private let sdk: SDK
    private let buildOptions: BuildOptions
    private let packageLocator: any PackageLocator
    private let fileSystem: any FileSystem

    private let productsDirectory: TSCAbsolutePath

    init(
        buildProduct: BuildProduct,
        sdk: SDK,
        buildOptions: BuildOptions,
        packageLocator: some PackageLocator,
        fileSystem: some FileSystem
    ) {
        self.buildProduct = buildProduct
        self.sdk = sdk
        self.buildOptions = buildOptions
        self.packageLocator = packageLocator
        self.fileSystem = fileSystem

        productsDirectory = packageLocator.productsDirectory(
            buildConfiguration: buildOptions.buildConfiguration,
            sdk: sdk
        )
    }

    func collectComponents(sdk: SDK) throws -> FrameworkComponents {
        let frameworkModuleMapPath: TSCAbsolutePath?
        if let customFrameworkModuleMapContents = buildOptions.customFrameworkModuleMapContents {
            logger.info("📝 Using custom modulemap for \(buildProduct.target.name)(\(sdk.displayName))")
            frameworkModuleMapPath = try copyModuleMapContentsToBuildArtifacts(customFrameworkModuleMapContents)
        } else {
            frameworkModuleMapPath = try generateFrameworkModuleMap()
        }

        let targetName = buildProduct.target.c99name
        let generatedFrameworkPath = generatedFrameworkPath()

        let binaryPath = generatedFrameworkPath.appending(component: targetName)

        let swiftModulesPath = try collectSwiftModules(
            of: targetName,
            in: generatedFrameworkPath
        )

        let bridgingHeaderPath = try collectBridgingHeader(
            of: targetName,
            in: generatedFrameworkPath
        )

        let publicHeaders = try collectPublicHeaders()

        let resourceBundlePath = generatedResourceBundlePath()

        let infoPlistPath = try collectInfoPlist(in: generatedFrameworkPath)

        let components = FrameworkComponents(
            frameworkName: buildProduct.target.name.packageNamed(),
            frameworkPath: generatedFrameworkPath,
            binaryPath: binaryPath,
            infoPlistPath: infoPlistPath,
            swiftModulesPath: swiftModulesPath,
            includeDir: (buildProduct.target.underlying as? ScipioClangModule)?.includeDir.scipioAbsolutePath,
            publicHeaderPaths: publicHeaders,
            bridgingHeaderPath: bridgingHeaderPath,
            modulemapPath: frameworkModuleMapPath,
            resourceBundlePath: resourceBundlePath
        )
        return components
    }

    /// Copy content data to the build artifacts
    private func copyModuleMapContentsToBuildArtifacts(_ data: Data) throws -> TSCAbsolutePath {
        let generatedModuleMapPath = try packageLocator.generatedModuleMapPath(of: buildProduct.target, sdk: sdk)

        try fileSystem.writeFileContents(generatedModuleMapPath.spmAbsolutePath, data: data)
        return generatedModuleMapPath
    }

    private func generateFrameworkModuleMap() throws -> TSCAbsolutePath? {
        let modulemapGenerator = FrameworkModuleMapGenerator(
            packageLocator: packageLocator,
            fileSystem: fileSystem
        )

        // xcbuild automatically generates modulemaps. However, these are not for frameworks.
        // Therefore, it's difficult to contain this generated modulemaps to final XCFrameworks.
        // So generate modulemap for frameworks manually
        let frameworkModuleMapPath = try modulemapGenerator.generate(
            resolvedTarget: buildProduct.target,
            sdk: sdk,
            keepPublicHeadersStructure: buildOptions.keepPublicHeadersStructure
        )
        return frameworkModuleMapPath
    }

    private func generatedFrameworkPath() -> TSCAbsolutePath {
        productsDirectory.appending(component: "\(buildProduct.target.c99name).framework")
    }

    private func generatedResourceBundlePath() -> TSCAbsolutePath? {
        guard let bundleName = buildProduct.target.underlying.bundleName else { return nil }

        let path = productsDirectory.appending(component: "\(bundleName).bundle")
        return fileSystem.exists(path) ? path : nil
    }

    private func collectInfoPlist(in frameworkBundlePath: TSCAbsolutePath) throws -> TSCAbsolutePath {
        let infoPlistLocationCandidates = [
            // In a regular framework bundle, Info.plist should be on its root
            frameworkBundlePath.appending(component: "Info.plist"),
            // In a versioned framework bundle (for macOS), Info.plist should be in Resources
            frameworkBundlePath.appending(components: "Resources", "Info.plist"),
        ]
        guard let infoPlistPath = infoPlistLocationCandidates.first(where: fileSystem.exists(_:)) else {
            throw Error.infoPlistNotFound(frameworkBundlePath: frameworkBundlePath)
        }
        return infoPlistPath
    }

    /// Collects *.swiftmodules* in a generated framework bundle
    private func collectSwiftModules(of targetName: String, in frameworkPath: TSCAbsolutePath) throws -> TSCAbsolutePath? {
        let swiftModulesPath = frameworkPath.appending(
            components: "Modules", "\(targetName).swiftmodule"
        )

        if fileSystem.exists(swiftModulesPath) {
            return swiftModulesPath
        }
        return nil
    }

    /// Collects a bridging header in a generated framework bundle
    private func collectBridgingHeader(of targetName: String, in frameworkPath: TSCAbsolutePath) throws -> TSCAbsolutePath? {
        let generatedBridgingHeader = frameworkPath.appending(
            components: "Headers", "\(targetName)-Swift.h"
        )

        if fileSystem.exists(generatedBridgingHeader) {
            return generatedBridgingHeader
        }

        return nil
    }

    /// Collects public headers of clangTarget
    private func collectPublicHeaders() throws -> Set<TSCAbsolutePath>? {
        guard let clangModule = buildProduct.target.underlying as? ScipioClangModule else {
            return nil
        }

        let publicHeaders = clangModule
            .headers
            .filter { $0.isDescendant(of: clangModule.includeDir) }
        let notSymlinks = publicHeaders.filter { !fileSystem.isSymlink($0) }
            .map { $0.scipioAbsolutePath }
        let symlinks = publicHeaders.filter { fileSystem.isSymlink($0) }

        // Sometimes, public headers include a file and its symlink both.
        // This situation raises a duplication error
        // So duplicated symlinks have to be omitted
        let notDuplicatedSymlinks = symlinks
            // `FileManager.contentsEqual` does not traverse symbolic links, but compares the links themselves.
            // So we need to resolve the links beforehand.
            .map { $0.asURL.resolvingSymlinksInPath() }
            .map(\.absolutePath)
            .filter { path in
                notSymlinks.allSatisfy { !FileManager.default.contentsEqual(atPath: path.pathString, andPath: $0.pathString) }
            }

        return Set(notSymlinks + notDuplicatedSymlinks)
    }
}
