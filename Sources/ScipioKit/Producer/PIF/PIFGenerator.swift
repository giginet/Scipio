import Foundation
import TSCBasic
import SPMBuildCore
import PackageModel
import PackageGraph
import XCBuildSupport

struct PIFGenerator {
    let package: Package
    let buildParameters: PIFBuilderParameters
    let buildOptions: BuildOptions
    private let fileSystem: any TSCBasic.FileSystem

    init(
        package: Package,
        buildParameters: BuildParameters,
        buildOptions: BuildOptions,
        fileSystem: any TSCBasic.FileSystem = TSCBasic.localFileSystem
    ) throws {
        self.package = package
        self.buildParameters = PIFBuilderParameters(buildParameters)
        self.buildOptions = buildOptions
        self.fileSystem = fileSystem
    }

    private func generatePIF() throws -> PIF.TopLevelObject {
        let pifBuilder = makePIFBuilder()
        return try pifBuilder.construct()
    }

    private func makePIFBuilder() -> PIFBuilder {
        PIFBuilder(
            graph: package.graph,
            parameters: buildParameters,
            fileSystem: fileSystem,
            observabilityScope: observabilitySystem.topScope
        )
    }

    func dumpJSON(for sdk: SDK, to path: AbsolutePath) throws {
        let topLevelObject = modify(try generatePIF(), for: sdk)

        try PIF.sign(topLevelObject.workspace)
        let encoder = JSONEncoder.makeWithDefaults()
        encoder.userInfo[.encodeForXCBuild] = true

        let newJSONData = try encoder.encode(topLevelObject)
        try fileSystem.writeFileContents(path, data: newJSONData)
    }

    private func modify(_ pif: PIF.TopLevelObject, for sdk: SDK) -> PIF.TopLevelObject {
        for project in pif.workspace.projects {
            for baseTarget in project.targets {
                if let target = baseTarget as? PIF.Target {
                    let isProductTarget = target.name.hasSuffix("Product")
                    let isObjectTarget = target.productType == .objectFile

                    if isObjectTarget || isProductTarget {
                        let targetName = target.name
                        target.productType = .framework
                        target.productName = "\(targetName).framework"
                    }

                    let newConfigurations = target.buildConfigurations.map { original in
                        var configuration = original
                        var settings = configuration.buildSettings

                        if isObjectTarget || isProductTarget {
                            let targetName = target.name
                            let executableName = targetName.spm_mangledToC99ExtendedIdentifier()

                            settings[.PRODUCT_NAME] = "$(EXECUTABLE_NAME:c99extidentifier)"
                            settings[.PRODUCT_MODULE_NAME] = "$(EXECUTABLE_NAME:c99extidentifier)"
                            settings[.EXECUTABLE_NAME] = executableName
                            settings[.TARGET_NAME] = targetName
                            settings[.PRODUCT_BUNDLE_IDENTIFIER] = targetName.spm_mangledToC99ExtendedIdentifier()
                            settings[.CLANG_ENABLE_MODULES] = "YES"
                            settings[.DEFINES_MODULE] = "YES"
                            settings[.SKIP_INSTALL] = "NO"
                            settings[.INSTALL_PATH] = "/usr/local/lib"
                            settings[.ONLY_ACTIVE_ARCH] = "NO"

                            switch buildOptions.frameworkType {
                            case .dynamic:
                                settings[.MACH_O_TYPE] = "mh_dylib"
                            case .static:
                                settings[.MACH_O_TYPE] = "staticlib"
                            }

                            settings[.LIBRARY_SEARCH_PATHS] = ["$(inherited)", "\(buildParameters.toolchainLibDir.pathString)/swift/\(sdk.settingValue)"]

                            settings[.GENERATE_INFOPLIST_FILE] = "YES"

                            // Set the project and marketing version for the framework because the app store requires these to be
                            // present. The AppStore requires bumping the project version when ingesting new builds but that's for
                            // top-level apps and not frameworks embedded inside it.
                            settings[.MARKETING_VERSION] = "1.0" // Version
                            settings[.CURRENT_PROJECT_VERSION] = "1" // Build

                            settings[.SWIFT_EMIT_MODULE_INTERFACE] = "YES"
                        }

                        // If the built framework is named same as one of the target in the package, it can be picked up
                        // automatically during indexing since the build system always adds a -F flag to the built products dir.
                        // To avoid this problem, we build all package frameworks in a subdirectory.
                        settings[.BUILT_PRODUCTS_DIR] = "$(BUILT_PRODUCTS_DIR)/PackageFrameworks"
                        settings[.TARGET_BUILD_DIR] = "$(TARGET_BUILD_DIR)/PackageFrameworks"

                        configuration.buildSettings = settings
                        return configuration
                    }

                    target.buildConfigurations = newConfigurations
                }
            }
        }
        return pif
    }
}
