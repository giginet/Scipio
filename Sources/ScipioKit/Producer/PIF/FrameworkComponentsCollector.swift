import Foundation
import TSCBasic
import PackageModel

/// FileLists to assemble a framework bundle
struct FrameworkComponents {
    var name: String
    var binaryPath: AbsolutePath
    var infoPlistPath: AbsolutePath
    var swiftModulesPath: AbsolutePath?
    var publicHeaderPaths: Set<AbsolutePath>?
    var bridgingHeaderPath: AbsolutePath?
    var modulemapPath: AbsolutePath?
    var resourceBundlePath: AbsolutePath?
}

/// A collector to collect framework components from a DerivedData dir
struct FrameworkComponentsCollector {
    enum Error: LocalizedError {
        case infoPlistNotFound(frameworkBundlePath: AbsolutePath)

        var errorDescription: String? {
            switch self {
            case .infoPlistNotFound(let frameworkBundlePath):
                return "Info.plist is not found in \(frameworkBundlePath.pathString)"
            }
        }
    }

    private let descriptionPackage: DescriptionPackage
    private let buildProduct: BuildProduct
    private let sdk: SDK
    private let buildOptions: BuildOptions
    private let fileSystem: any FileSystem

    init(
        descriptionPackage: DescriptionPackage,
        buildProduct: BuildProduct,
        sdk: SDK,
        buildOptions: BuildOptions,
        fileSystem: any FileSystem
    ) {
        self.descriptionPackage = descriptionPackage
        self.buildProduct = buildProduct
        self.sdk = sdk
        self.buildOptions = buildOptions
        self.fileSystem = fileSystem
    }

    func collectComponents(sdk: SDK) throws -> FrameworkComponents {
        let modulemapGenerator = ModuleMapGenerator(
            descriptionPackage: descriptionPackage,
            fileSystem: fileSystem
        )

        // xcbuild automatically generates modulemaps. However, these are not for frameworks.
        // Therefore, it's difficult to contain to final XCFrameworks.
        // So generate modulemap for frameworks manually
        let frameworkModuleMapPath = try modulemapGenerator.generate(
            resolvedTarget: buildProduct.target,
            sdk: sdk,
            buildConfiguration: buildOptions.buildConfiguration
        )

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

        let publicHeaders = try collectPublicHeader()

        let resourceBundlePath = try collectResourceBundle(
            of: targetName,
            in: generatedFrameworkPath
        )

        let infoPlistPath = try findInfoPlist(in: generatedFrameworkPath)

        let components = FrameworkComponents(
            name: buildProduct.target.name.packageNamed(),
            binaryPath: binaryPath,
            infoPlistPath: infoPlistPath,
            swiftModulesPath: swiftModulesPath,
            publicHeaderPaths: publicHeaders,
            bridgingHeaderPath: bridgingHeaderPath,
            modulemapPath: frameworkModuleMapPath,
            resourceBundlePath: resourceBundlePath
        )
        return components
    }

    private func generatedFrameworkPath() -> AbsolutePath {
        descriptionPackage.productsDirectory(
            buildConfiguration: buildOptions.buildConfiguration,
            sdk: sdk
        )
        .appending(component: "\(buildProduct.target.c99name).framework")
    }

    private func findInfoPlist(in frameworkBundlePath: AbsolutePath) throws -> AbsolutePath {
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
    private func collectSwiftModules(of targetName: String, in frameworkPath: AbsolutePath) throws -> AbsolutePath? {
        let swiftModulesPath = frameworkPath.appending(
            components: "Modules", "\(targetName).swiftmodule"
        )

        if fileSystem.exists(swiftModulesPath) {
            return swiftModulesPath
        }
        return nil
    }

    /// Collects a bridging header in a generated framework bundle
    private func collectBridgingHeader(of targetName: String, in frameworkPath: AbsolutePath) throws -> AbsolutePath? {
        let generatedBridgingHeader = frameworkPath.appending(
            components: "Headers", "\(targetName)-Swift.h"
        )

        if fileSystem.exists(generatedBridgingHeader) {
            return generatedBridgingHeader
        }

        return nil
    }

    /// Collects public headers of clangTarget
    private func collectPublicHeader() throws -> Set<AbsolutePath>? {
        guard let clangTarget = buildProduct.target.underlyingTarget as? ClangTarget else {
            return nil
        }

        let publicHeaders = try clangTarget
            .headers
            .filter { $0.isDescendant(of: clangTarget.includeDir) }
            // Follow symlink
            .map { $0.asURL.resolvingSymlinksInPath() }
            .map { try AbsolutePath(validating: $0.path) }
        return Set(publicHeaders)
    }

    private func collectResourceBundle(of targetName: String, in frameworkPath: AbsolutePath) throws -> AbsolutePath? {
        let bundleFileName = try fileSystem.getDirectoryContents(frameworkPath).first { $0.hasSuffix(".bundle") }
        return bundleFileName.flatMap { frameworkPath.appending(component: $0) }
    }
}
