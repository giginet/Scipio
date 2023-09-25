import Foundation
import TSCBasic
import SPMBuildCore
import PackageModel
import PackageGraph
import XCBuildSupport

extension PIF.Target {
    fileprivate enum TargetType {
        case library
        case resourceBundle
    }

    fileprivate var supportedType: TargetType? {
        switch productType {
        case .objectFile:
            return .library
        case .bundle:
            return .resourceBundle
        default: // unsupported types
            return nil
        }
    }
}

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
            packageGraph: descriptionPackage.graph,
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
            project.targets = project.targets
                .compactMap { $0 as? PIF.Target }
                .compactMap { target in
                    guard let supportedType = target.supportedType else { return target }

                    switch supportedType {
                    case .library:
                        let modifier = PIFLibraryTargetModifier(
                            descriptionPackage: descriptionPackage,
                            buildParameters: buildParameters,
                            buildOptions: buildOptions,
                            fileSystem: fileSystem,
                            project: project,
                            pifTarget: target,
                            sdk: sdk
                        )

                        return modifier.modify()
                    case .resourceBundle:
                        generateInfoPlistForResource(for: target)
                        return target
                    }
                }
        }
        return pif
    }

    private func generateInfoPlistForResource(for pifTarget: PIF.Target) {
        assert(pifTarget.supportedType == .resourceBundle, "This method must be called for Resource bundles")

        let infoPlistGenerator = InfoPlistGenerator(fileSystem: fileSystem)
        let infoPlistPath = descriptionPackage.workspaceDirectory.appending(component: "Info-\(pifTarget.productName).plist")
        do {
            try infoPlistGenerator.generate(for: .bundle, at: infoPlistPath)
        } catch {
            fatalError("Could not generate Info.plist file")
        }

        let newConfigurations = pifTarget.buildConfigurations.map { original in
            var configuration = original
            var settings = configuration.buildSettings

            // For resource bundle targets, generating Info.plist automatically in default.
            // However, generated Info.plist causes code signing issue when submitting to AppStore.
            // `CFBundleExecutable` is not allowed for Info.plist contains in resource bundles.
            // So generating a Info.plist and set this
            settings[.GENERATE_INFOPLIST_FILE] = "NO"
            settings[.INFOPLIST_FILE] = infoPlistPath.pathString

            configuration.buildSettings = settings
            return configuration
        }

        pifTarget.buildConfigurations = newConfigurations
    }
}

private struct PIFLibraryTargetModifier {
    private let descriptionPackage: DescriptionPackage
    private let buildParameters: BuildParameters
    private let buildOptions: BuildOptions
    private let fileSystem: any FileSystem

    private let project: PIF.Project
    private let pifTarget: PIF.Target
    private let sdk: SDK

    private let resolvedPackage: ResolvedPackage
    private let resolvedTarget: ResolvedTarget

    init(
        descriptionPackage: DescriptionPackage,
        buildParameters: BuildParameters,
        buildOptions: BuildOptions,
        fileSystem: any FileSystem,
        project: PIF.Project,
        pifTarget: PIF.Target,
        sdk: SDK
    ) {
        precondition(pifTarget.supportedType == .library, "PIFLibraryTargetModifier must be for library targets")

        self.descriptionPackage = descriptionPackage
        self.buildParameters = buildParameters
        self.buildOptions = buildOptions
        self.fileSystem = fileSystem
        self.project = project
        self.pifTarget = pifTarget
        self.sdk = sdk

        let c99Name = pifTarget.name.spm_mangledToC99ExtendedIdentifier()

        guard let resolvedTarget = descriptionPackage.graph.allTargets.first(where: { $0.c99name == c99Name }) else {
            fatalError("Resolved Target named \(c99Name) is not found.")
        }

        guard let resolvedPackage = descriptionPackage.graph.package(for: resolvedTarget) else {
            fatalError("Could not find a package")
        }

        self.resolvedTarget = resolvedTarget
        self.resolvedPackage = resolvedPackage
    }

    private var c99Name: String {
        resolvedTarget.c99name
    }

    func modify() -> PIF.Target {
        updateLibraryTargetSettings()

        return pifTarget
    }

    private func updateLibraryTargetSettings() {
        pifTarget.productType = .framework

        let newConfigurations = pifTarget.buildConfigurations.map(updateBuildConfiguration)

        pifTarget.buildConfigurations = newConfigurations

        addLinkSettings(of: pifTarget)
    }

    private func updateBuildConfiguration(_ original: PIF.BuildConfiguration) -> PIF.BuildConfiguration {
        var configuration = original
        var settings = configuration.buildSettings
        let name = pifTarget.name
        let c99Name = name.spm_mangledToC99ExtendedIdentifier()

        let toolchainLibDir = (try? buildParameters.toolchain.toolchainLibDir) ?? .root

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
        settings[.GENERATE_INFOPLIST_FILE] = "YES"

        // Set framework type
        switch buildOptions.frameworkType {
        case .dynamic:
            settings[.MACH_O_TYPE] = "mh_dylib"
        case .static:
            settings[.MACH_O_TYPE] = "staticlib"
        }

        settings[.LIBRARY_SEARCH_PATHS, default: ["$(inherited)"]]
            .append("\(toolchainLibDir.pathString)/swift/\(sdk.settingValue)")

        // Enable to emit swiftinterface
        if buildOptions.enableLibraryEvolution {
            settings[.OTHER_SWIFT_FLAGS, default: ["$(inherited)"]]
                .append("-enable-library-evolution")
            settings[.SWIFT_EMIT_MODULE_INTERFACE] = "YES"
        }
        settings[.SWIFT_INSTALL_OBJC_HEADER] = "YES"

        // Original PIFBuilder implementation of SwiftPM generates modulemap for Swift target
        // That modulemap refer a bridging header by a relative path
        // However, this PIFGenerator modified productType to framework. So a bridging header will be generated in frameworks bundle even if `SWIFT_OBJC_INTERFACE_HEADER_DIR` was specified.
        // So it's need to replace `MODULEMAP_FILE_CONTENTS` to an absolute path.
        if let swiftTarget = resolvedTarget.underlyingTarget as? SwiftTarget {
            // Bridging Headers will be generated inside generated frameworks
            let productsDirectory = descriptionPackage.productsDirectory(
                buildConfiguration: buildOptions.buildConfiguration,
                sdk: sdk
            )
            let bridgingHeaderFullPath = productsDirectory.appending(
                components: ["\(swiftTarget.c99name).framework", "Headers", "\(swiftTarget.name)-Swift.h"]
            )

            settings[.MODULEMAP_FILE_CONTENTS] = """
                module \(swiftTarget.c99name) {
                    header "\(bridgingHeaderFullPath.pathString)"
                    export *
                }
                """
        }

        configuration.buildSettings = settings

        return configuration
    }

    private func guid(_ suffixes: String...) -> String {
        "GUID::SCIPIO::\(pifTarget.name)::" + suffixes.joined(separator: "::")
    }

    // Add dependencies to "Link Binary with Libraries" phase
    // PIFBuilder of SwiftPM links dependencies only to PackageProduct
    // This method will link all dependencies to library targets
    private func addLinkSettings(of pifTarget: PIF.Target) {
        let allBinaryTargets: [BinaryTarget] = resolvedTarget.dependencies.reduce([]) { (binaryTargets, dependency) in
            if let product = dependency.product {
                return binaryTargets + product.targets.map(\.underlyingTarget).compactMap { $0 as? BinaryTarget }
            } else if let target = dependency.target, let binaryTarget = target.underlyingTarget as? BinaryTarget {
                return binaryTargets + [binaryTarget]
            }
            return binaryTargets
        }

        func shouldLink(_ dependency: PIF.TargetDependency) -> Bool {
            switch buildOptions.frameworkType {
            case .dynamic:
                // For dynamic frameworks, all dependencies should be linked
                return true
            case .static:
                // For static frameworks, only binaryTargets should be linked avoiding to symbol duplication
                // targetGUID should be `PACKAGE-PRODUCT:<target_name>`
                guard let targetName = dependency.targetGUID.split(separator: ":").last else { return false }
                return allBinaryTargets.contains { $0.name == targetName }
            }
        }

        let linkingDependencies = pifTarget.dependencies.filter(shouldLink(_:))

        let buildFiles = linkingDependencies.enumerated().map { (index, dependency) in
            PIF.BuildFile(guid: guid("FRAMEWORKS_BUILD_FILE_\(index)"),
                          targetGUID: dependency.targetGUID,
                          platformFilters: dependency.platformFilters)
        }

        if let buildPhase = fetchBuildPhase(of: PIF.FrameworksBuildPhase.self, in: pifTarget) {
            buildPhase.buildFiles.append(contentsOf: buildFiles)
        } else {
            let buildPhase = PIF.FrameworksBuildPhase(
               guid: guid("FRAMEWORKS_BUILD_PHASE"),
               buildFiles: buildFiles
            )
            pifTarget.buildPhases.append(buildPhase)
        }
    }

    private func fetchBuildPhase<BuildPhase: PIF.BuildPhase>(of buildPhasesType: BuildPhase.Type, in pifTarget: PIF.Target) -> BuildPhase? {
        pifTarget.buildPhases.compactMap({ $0 as? BuildPhase }).first
    }
}

extension PIF.TopLevelObject: Decodable {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        self.init(workspace: try container.decode(PIF.Workspace.self))
    }
}

extension AbsolutePath {
    fileprivate var moduleEscapedPathString: String {
        return self.pathString.replacingOccurrences(of: "\\", with: "\\\\")
    }
}
