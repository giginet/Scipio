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

                    updateCommonSettings(of: target)

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
                        return target
                    }
                }
        }
        return pif
    }

    private func updateCommonSettings(of pifTarget: PIF.Target) {
        let newConfigurations = pifTarget.buildConfigurations.map { original in
            var configuration = original
            var settings = configuration.buildSettings

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
        pifTarget.productName = "\(c99Name).framework"

        let newConfigurations = pifTarget.buildConfigurations.map(updateBuildConfiguration)

        pifTarget.buildConfigurations = newConfigurations

        if let clangTarget = resolvedTarget.underlyingTarget as? ClangTarget {
            addPublicHeaders(clangTarget: clangTarget)
        }

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

        // Set framework type
        switch buildOptions.frameworkType {
        case .dynamic:
            settings[.MACH_O_TYPE] = "mh_dylib"
        case .static:
            settings[.MACH_O_TYPE] = "staticlib"
        }

        settings[.LIBRARY_SEARCH_PATHS, default: ["$(inherited)"]]
            .append("\(toolchainLibDir.pathString)/swift/\(sdk.settingValue)")

        settings[.GENERATE_INFOPLIST_FILE] = "YES"

        settings[.MARKETING_VERSION] = "1.0" // Version
        settings[.CURRENT_PROJECT_VERSION] = "1" // Build

        // Enable to emit swiftinterface
        if buildOptions.enableLibraryEvolution {
            settings[.OTHER_SWIFT_FLAGS, default: ["$(inherited)"]]
                .append("-enable-library-evolution")
            settings[.SWIFT_EMIT_MODULE_INTERFACE] = "YES"
        }
        settings[.SWIFT_INSTALL_OBJC_HEADER] = "YES"

        let generator = ModuleMapGenerator(
            descriptionPackage: descriptionPackage,
            sdk: sdk,
            configuration: buildOptions.buildConfiguration,
            resolvedTarget: resolvedTarget,
            fileSystem: fileSystem
        )

        if let result = try? generator.generate() {
            print("generatedModuleMap", result.moduleMapPath.pathString)
            settings[.MODULEMAP_FILE] = result.moduleMapPath.pathString
        }
        
        configuration.buildSettings = settings
        return configuration
    }

    private func collectPublicHeaders(of clangTarget: ClangTarget) -> Set<AbsolutePath> {
        let publicHeaders = clangTarget
            .headers
            .filter { $0.isDescendant(of: clangTarget.includeDir) }
        let notSymlinks = publicHeaders.filter { !fileSystem.isSymlink($0) }
        let symlinks = publicHeaders.filter { fileSystem.isSymlink($0) }

        // Sometimes, public headers include a file and its symlink both.
        // This situation raises a duplication error
        // So duplicated symlinks have to be omitted
        let notDuplicatedSymlinks = symlinks.filter { path in
            notSymlinks.allSatisfy { FileManager.default.contentsEqual(atPath: path.pathString, andPath: $0.pathString) }
        }

        return Set(notSymlinks + notDuplicatedSymlinks)
    }

    private func guid(_ suffixes: String...) -> String {
        "GUID::SCIPIO::\(pifTarget.name)::" + suffixes.joined(separator: "::")
    }

    private func addPublicHeaders(clangTarget: ClangTarget) {
        let packageRootDir = resolvedPackage.path
        let targetRootDir = clangTarget.path
        let targetGroupName = targetRootDir.relative(to: packageRootDir).pathString
        let includeDir = clangTarget.includeDir
        let targetGroup = project.groupTree.children
            .compactMap { $0 as? PIF.Group }
            .first { $0.name == targetGroupName }
        guard let targetGroup else {
            fatalError("Groups \(targetGroupName) not found")
        }
        let publicHeadersGroup = PIF.Group(
            guid: guid("GROUPS", "HEADERS"),
            path: includeDir.relative(to: targetRootDir).pathString,
            sourceTree: .group,
            children: []
        )
        targetGroup.children.append(publicHeadersGroup)

        let headers = collectPublicHeaders(of: clangTarget)
        let fileReference = headers.enumerated().map { (index, headerPath) in
            let relativePath = headerPath.relative(to: includeDir)
            return PIF.FileReference(
                guid: guid("HEADERS_FILE_REFERENCE_\(index)"),
                path: relativePath.pathString,
                sourceTree: .group
            )
        }

        fileReference.forEach { publicHeadersGroup.children.append($0) }

        let buildFiles = fileReference.enumerated().map { (index, reference) in
            PIF.BuildFile(
                guid: guid("HEADERS_BUILD_FILE_\(index)"),
                file: reference,
                platformFilters: [],
                headerVisibility: .public
            )
        }

        if let buildPhase = fetchBuildPhase(of: PIF.HeadersBuildPhase.self, in: pifTarget) {
            buildPhase.buildFiles.append(contentsOf: buildFiles)
        } else {
            let buildPhase = PIF.HeadersBuildPhase(
               guid: guid("HEADERS_BUILD_PHASE"),
               buildFiles: buildFiles
            )
            pifTarget.buildPhases.append(buildPhase)
        }
    }

    private func addLinkSettings(of pifTarget: PIF.Target) {
        let buildFiles = pifTarget.dependencies.enumerated().map { (index, dependency) in
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
                    umbrella header "\(headerPath.moduleEscapedPathString)"
                    export *
                }
                """
                    .trimmingCharacters(in: .whitespaces)
            case .umbrellaDirectory(let directoryPath):
                return """
                framework module \(resolvedTarget.c99name) {
                    umbrella "\(directoryPath.moduleEscapedPathString)"
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
        // .build/scipio/DerivedData/swift-nio/CNIOAtomics/Intermediates.noindex/GeneratedModuleMaps/iphoneos
        // $(OBJROOT)/GeneratedModuleMaps/$(PLATFORM_NAME)
        let moduleMapPath = try RelativePath(validating: "./Intermediates.noindex/GeneratedModuleMaps/\(sdk.settingValue)/\(resolvedTarget.name).modulemap")
        return descriptionPackage.derivedDataPath(for: resolvedTarget)
            .appending(moduleMapPath)
    }

    func generate() throws -> ModuleMapResult? {
        if let clangTarget = resolvedTarget.underlyingTarget as? ClangTarget {
            switch clangTarget.moduleMapType {
            case .custom(let moduleMapPath):
                let path = try AbsolutePath(validating: moduleMapPath.moduleEscapedPathString)
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
