import Foundation
import TSCBasic
import PackageModel

/// FileLists to assemble a framework bundle
struct FrameworkComponents {
    var name: String
    var binaryPath: AbsolutePath
    var swiftModulesPath: AbsolutePath?
    var publicHeaderPaths: Set<AbsolutePath>?
    var bridgingHeaderPath: AbsolutePath?
    var modulemapPath: AbsolutePath?
}

/// A collector to collect framework components from a DerivedData dir
struct FrameworkComponentsCollector {
    private let descriptionPackage: DescriptionPackage
    private let buildProduct: BuildProduct
    private let buildOptions: BuildOptions
    private let fileSystem: any FileSystem

    init(
        descriptionPackage: DescriptionPackage,
        buildProduct: BuildProduct,
        buildOptions: BuildOptions,
        fileSystem: any FileSystem
    ) {
        self.descriptionPackage = descriptionPackage
        self.buildProduct = buildProduct
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
        let productDir = descriptionPackage.productsDirectory(
            buildConfiguration: buildOptions.buildConfiguration,
            sdk: sdk
        )

        let targetName = buildProduct.target.c99name

        let binaryPath = productDir.appending(components: "\(targetName).framework", targetName)

        let swiftModulesPath = try findSwiftModules(of: targetName, in: productDir)

        let bridgingHeaderPath = try findBridgingHeader(sdk: sdk)

        let publicHeaders = try collectPublicHeader()

        let components = FrameworkComponents(
            name: buildProduct.target.name.packageNamed(),
            binaryPath: binaryPath,
            swiftModulesPath: swiftModulesPath,
            publicHeaderPaths: publicHeaders,
            bridgingHeaderPath: bridgingHeaderPath,
            modulemapPath: frameworkModuleMapPath
        )
        return components
    }

    /// Find *.swiftmodules*
    private func findSwiftModules(of targetName: String, in productDir: AbsolutePath) throws -> AbsolutePath? {
        let swiftModulesPath = productDir.appending(component: "\(targetName).swiftmodule")

        if fileSystem.exists(swiftModulesPath) {
            return swiftModulesPath
        }
        return nil
    }

    /// Find bridging header under $(SWIFT_OBJC_INTERFACE_HEADER_DIR)
    /// It will be $(OBJROOT)/GeneratedModuleMaps/$(PLATFORM_NAME)/*-Swift.h
    private func findBridgingHeader(sdk: SDK) throws -> AbsolutePath? {
        let target = buildProduct.target
        let generatedModuleMapDirectoryPath = descriptionPackage.derivedDataPath.appending(
            components: "Intermediates.noindex", "GeneratedModuleMaps", sdk.settingValue
        )
        let generatedBridgingHeader = generatedModuleMapDirectoryPath.appending(component: "\(target.c99name)-Swift.h")

        if fileSystem.exists(generatedBridgingHeader) {
            return generatedBridgingHeader
        }

        return nil
    }

    /// Collect public headers of clangTarget
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
}
