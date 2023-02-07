import Foundation
import TSCBasic
import SPMBuildCore
import PackageModel
import PackageGraph
import XCBuildSupport

struct PIFGenerator {
    private let descriptionPackage: DescriptionPackage
    private let buildParameters: BuildParameters
    private let buildOptions: BuildOptions
    private let fileSystem: any FileSystem

    init(
        package: DescriptionPackage,
        buildParameters: BuildParameters,
        buildOptions: BuildOptions,
        fileSystem: any FileSystem = TSCBasic.localFileSystem
    ) throws {
        self.descriptionPackage = package
        self.buildParameters = buildParameters
        self.buildOptions = buildOptions
        self.fileSystem = fileSystem
    }

    private func generatePIF() throws -> PIF.TopLevelObject {
        // A constructor of PIFBuilder is concealed. So use JSON is only way to get PIF structs.
        let jsonString = try PIFBuilder.generatePIF(
            buildParameters: buildParameters,
            packageGraph: package.graph,
            fileSystem: localFileSystem,
            observabilityScope: observabilitySystem.topScope,
            preservePIFModelStructure: true
        )
        let data = jsonString.data(using: .utf8)!
        let jsonDecoder = JSONDecoder.makeWithDefaults()
        return try jsonDecoder.decode(PIF.TopLevelObject.self, from: data)
    }

    func generateJSON(for sdk: SDK) throws -> AbsolutePath {
        let topLevelObject = modify(try generatePIF(), for: sdk)

        try PIF.sign(topLevelObject.workspace)
        let encoder = JSONEncoder.makeWithDefaults()
        encoder.userInfo[.encodeForXCBuild] = true

        let newJSONData = try encoder.encode(topLevelObject)
        let path = descriptionPackage.workspaceDirectory
            .appending(component: "manifest-\(descriptionPackage.name)-\(sdk.settingValue).pif")
        try fileSystem.writeFileContents(path, data: newJSONData)
        return path
    }

    private func modify(_ pif: PIF.TopLevelObject, for sdk: SDK) -> PIF.TopLevelObject {
        for project in pif.workspace.projects {
            for baseTarget in project.targets {
                if let pifTarget = baseTarget as? PIF.Target {
                    let isObjectTarget = pifTarget.productType == .objectFile

                    guard [.objectFile, .bundle].contains(pifTarget.productType) else { continue }

                    let name = pifTarget.name
                    let c99Name = pifTarget.name.spm_mangledToC99ExtendedIdentifier()

                    if isObjectTarget {
                        pifTarget.productType = .framework
                        pifTarget.productName = "\(name).framework"
                    }

                    let newConfigurations = pifTarget.buildConfigurations.map { original in
                        var configuration = original
                        var settings = configuration.buildSettings

                        let toolchainLibDir = (try? buildParameters.toolchain.toolchainLibDir) ?? .root

                        if isObjectTarget {
                            settings[.PRODUCT_NAME] = "$(EXECUTABLE_NAME:c99extidentifier)"
                            settings[.PRODUCT_MODULE_NAME] = "$(EXECUTABLE_NAME:c99extidentifier)"
                            settings[.EXECUTABLE_NAME] = c99Name
                            settings[.TARGET_NAME] = name
                            settings[.PRODUCT_BUNDLE_IDENTIFIER] = name.spm_mangledToBundleIdentifier()
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

                            settings[.LIBRARY_SEARCH_PATHS, default: ["$(inherited)"]]
                                .append("\(toolchainLibDir.pathString)/swift/\(sdk.settingValue)")

                            settings[.GENERATE_INFOPLIST_FILE] = "YES"

                            // Set the project and marketing version for the framework because the app store requires these to be
                            // present. The AppStore requires bumping the project version when ingesting new builds but that's for
                            // top-level apps and not frameworks embedded inside it.
                            settings[.MARKETING_VERSION] = "1.0" // Version
                            settings[.CURRENT_PROJECT_VERSION] = "1" // Build

                            // Enable `-enable-library-evolution` to emit swiftinterface
                            settings[.OTHER_SWIFT_FLAGS, default: ["$(inherited)"]]
                                .append("-enable-library-evolution")

                            settings[.SWIFT_EMIT_MODULE_INTERFACE] = "YES"
                            // Add Bridging Headers to frameworks
                            settings[.SWIFT_INSTALL_OBJC_HEADER] = "YES"

                            pifTarget.impartedBuildProperties.buildSettings[.OTHER_CFLAGS] = ["$(inherited)"]

                            // Add auto-generated modulemap
                            settings[.MODULEMAP_PATH] = nil
                            // Generate modulemap supporting Framework
                            settings[.MODULEMAP_FILE_CONTENTS] = """
                framework module \(c99Name) {
                    header "\(name)-Swift.h"
                    export *
                }
                """
                        }

                        // If the built framework is named same as one of the target in the package, it can be picked up
                        // automatically during indexing since the build system always adds a -F flag to the built products dir.
                        // To avoid this problem, we build all package frameworks in a subdirectory.
                        settings[.BUILT_PRODUCTS_DIR] = "$(BUILT_PRODUCTS_DIR)/PackageFrameworks"
                        settings[.TARGET_BUILD_DIR] = "$(TARGET_BUILD_DIR)/PackageFrameworks"

                        configuration.buildSettings = settings
                        return configuration
                    }

                    pifTarget.buildConfigurations = newConfigurations
                }
            }
        }
        return pif
    }
}

extension PIF.TopLevelObject: Decodable {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        self.init(workspace: try container.decode(PIF.Workspace.self))
    }
}
