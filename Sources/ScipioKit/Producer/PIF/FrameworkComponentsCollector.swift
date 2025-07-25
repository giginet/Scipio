import Foundation

/// FileLists to assemble a framework bundle
struct FrameworkComponents {
    /// Whether the built framework is a versioned bundle or not.
    ///
    /// In general, frameworks for macOS would be this format.
    ///
    /// - seealso: https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPFrameworks/Concepts/FrameworkAnatomy.html
    var isVersionedBundle: Bool
    var frameworkName: String
    var frameworkPath: URL
    var binaryPath: URL
    var infoPlistPath: URL
    var swiftModulesPath: URL?
    var includeDir: URL?
    var publicHeaderPaths: Set<URL>?
    var bridgingHeaderPath: URL?
    var modulemapPath: URL?
    var resourceBundlePath: URL?
}

/// A collector to collect framework components from a DerivedData dir
struct FrameworkComponentsCollector {
    enum Error: LocalizedError {
        case infoPlistNotFound(frameworkBundlePath: URL)

        var errorDescription: String? {
            switch self {
            case .infoPlistNotFound(let frameworkBundlePath):
                return "Info.plist is not found in \(frameworkBundlePath.path(percentEncoded: false))"
            }
        }
    }

    private let buildProduct: BuildProduct
    private let sdk: SDK
    private let buildOptions: BuildOptions
    private let packageLocator: any PackageLocator
    private let fileSystem: any FileSystem

    private let productsDirectory: URL

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
        let frameworkModuleMapPath: URL?
        if let customFrameworkModuleMapContents = buildOptions.customFrameworkModuleMapContents {
            logger.info("📝 Using custom modulemap for \(buildProduct.target.name)(\(sdk.displayName))")
            frameworkModuleMapPath = try copyModuleMapContentsToBuildArtifacts(customFrameworkModuleMapContents)
        } else {
            frameworkModuleMapPath = try generateFrameworkModuleMap()
        }

        let targetName = buildProduct.target.c99name
        let generatedFrameworkPath = generatedFrameworkPath()

        let isVersionedBundle = fileSystem.exists(
            generatedFrameworkPath.appending(component: "Resources"),
            followSymlink: true
        )

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

        let infoPlistPath = try collectInfoPlist(
            in: generatedFrameworkPath,
            isVersionedBundle: isVersionedBundle
        )

        let components = FrameworkComponents(
            isVersionedBundle: isVersionedBundle,
            frameworkName: buildProduct.target.name.packageNamed(),
            frameworkPath: generatedFrameworkPath,
            binaryPath: binaryPath,
            infoPlistPath: infoPlistPath,
            swiftModulesPath: swiftModulesPath,
            includeDir: buildProduct.target.resolvedModuleType.includeDir,
            publicHeaderPaths: publicHeaders,
            bridgingHeaderPath: bridgingHeaderPath,
            modulemapPath: frameworkModuleMapPath,
            resourceBundlePath: resourceBundlePath
        )
        return components
    }

    /// Copy content data to the build artifacts
    private func copyModuleMapContentsToBuildArtifacts(_ data: Data) throws -> URL {
        let generatedModuleMapPath = try packageLocator.generatedModuleMapPath(of: buildProduct.target, sdk: sdk)

        try fileSystem.writeFileContents(generatedModuleMapPath, data: data)
        return generatedModuleMapPath
    }

    private func generateFrameworkModuleMap() throws -> URL? {
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

    private func generatedFrameworkPath() -> URL {
        productsDirectory.appending(component: "\(buildProduct.target.c99name).framework")
    }

    private func generatedResourceBundlePath() -> URL? {
        let bundleName: String? = buildProduct.target.underlying.bundleName(for: buildProduct.package.manifest)

        guard let bundleName else { return nil }

        let path = productsDirectory.appending(component: "\(bundleName).bundle")
        return fileSystem.exists(path) ? path : nil
    }

    private func collectInfoPlist(
        in frameworkBundlePath: URL,
        isVersionedBundle: Bool
    ) throws -> URL {
        let infoPlistLocation = if isVersionedBundle {
            // In a versioned framework bundle (for macOS), Info.plist should be in Resources
            frameworkBundlePath.appending(components: "Resources", "Info.plist")
        } else {
            // In a regular framework bundle, Info.plist should be on its root
            frameworkBundlePath.appending(component: "Info.plist")
        }

        if fileSystem.exists(infoPlistLocation) {
            return infoPlistLocation
        } else {
            throw Error.infoPlistNotFound(frameworkBundlePath: frameworkBundlePath)
        }
    }

    /// Collects *.swiftmodules* in a generated framework bundle
    private func collectSwiftModules(of targetName: String, in frameworkPath: URL) throws -> URL? {
        let swiftModulesPath = frameworkPath.appending(
            components: "Modules", "\(targetName).swiftmodule"
        )

        if fileSystem.exists(swiftModulesPath) {
            return swiftModulesPath
        }
        return nil
    }

    /// Collects a bridging header in a generated framework bundle
    private func collectBridgingHeader(of targetName: String, in frameworkPath: URL) throws -> URL? {
        let generatedBridgingHeader = frameworkPath.appending(
            components: "Headers", "\(targetName)-Swift.h"
        )

        if fileSystem.exists(generatedBridgingHeader) {
            return generatedBridgingHeader
        }

        return nil
    }

    /// Collects public headers of clangTarget
    private func collectPublicHeaders() throws -> Set<URL>? {
        guard case let .clang(_, publicHeaders) = buildProduct.target.resolvedModuleType else {
            return nil
        }

        let notSymlinks = publicHeaders.filter { !fileSystem.isSymlink($0) }
        let symlinks = publicHeaders.filter { fileSystem.isSymlink($0) }

        // Sometimes, public headers include a file and its symlink both.
        // This situation raises a duplication error
        // So duplicated symlinks have to be omitted
        let notDuplicatedSymlinks = symlinks
            // `FileManager.contentsEqual` does not traverse symbolic links, but compares the links themselves.
            // So we need to resolve the links beforehand.
            .map { $0.resolvingSymlinksInPath() }
            .filter { path in
                notSymlinks.allSatisfy {
                    !FileManager.default.contentsEqual(
                        atPath: path.path(percentEncoded: false),
                        andPath: $0.path(percentEncoded: false)
                    )
                }
            }

        return Set(notSymlinks + notDuplicatedSymlinks)
    }
}
