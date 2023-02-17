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

    private enum TargetType {
        case library
        case resourceBundle
    }

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
                    guard let targetType = detectSupportedType(of: target) else { return target }
                    updateCommonSettings(of: target, for: sdk)

                    if case .library = targetType {
                        updateLibraryTargetSettings(of: target, project: project, for: sdk)
                    }
                    return target
            }
        }
        return pif
    }

    private func detectSupportedType(of pifTarget: PIF.Target) -> TargetType? {
        switch pifTarget.productType {
        case .objectFile:
            return .library
        case .bundle:
            return .resourceBundle
        default: // unsupported types
            return nil
        }
    }

    private func updateLibraryTargetSettings(of pifTarget: PIF.Target, project: PIF.Project, for sdk: SDK) {
        let name = pifTarget.name
        let c99Name = pifTarget.name.spm_mangledToC99ExtendedIdentifier()
        pifTarget.productType = .framework
        pifTarget.productName = "\(c99Name).framework"

        guard let resolvedTarget = descriptionPackage.graph.allTargets.first(where: { $0.c99name == c99Name }) else {
            fatalError("Resolved Target named \(c99Name) is not found.")
        }

        let newConfigurations = pifTarget.buildConfigurations.map { original in
            var configuration = original
            var settings = configuration.buildSettings

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

            // Generating modulemap to default location
            // Location set by the original PIFBuilder may not be work
            settings[.MODULEMAP_PATH] = nil
            // Removing `-fmodule-map-file` flag set on the original PIFBuilder
            pifTarget.impartedBuildProperties.buildSettings[.OTHER_CFLAGS] = ["$(inherited)"]
            pifTarget.impartedBuildProperties.buildSettings[.OTHER_SWIFT_FLAGS] = ["$(inherited)"]

            if let clangTarget = resolvedTarget.underlyingTarget as? ClangTarget {
                switch clangTarget.moduleMapType {
                case .custom(let moduleMapPath):
                    settings[.MODULEMAP_FILE] = moduleMapPath.moduleEscapedPathString
                    settings[.MODULEMAP_FILE_CONTENTS] = nil
                case .umbrellaHeader(let headerPath):
                    settings[.MODULEMAP_FILE_CONTENTS] = """
                        framework module \(c99Name) {
                            umbrella header "\(headerPath.moduleEscapedPathString)"
                            export *
                        }
                    """
                case .umbrellaDirectory(let directoryPath):
                    settings[.MODULEMAP_FILE_CONTENTS] = """
                        framework module \(c99Name) {
                            umbrella "\(directoryPath.moduleEscapedPathString)"
                            export *
                        }
                    """
                case .none:
                    settings[.MODULEMAP_FILE_CONTENTS] = nil
                }
            } else {
                let bridgingHeaderName = settings[.SWIFT_OBJC_INTERFACE_HEADER_NAME] ?? "\(name)-Swift.h"
                settings[.MODULEMAP_FILE_CONTENTS] = """
                    framework module \(c99Name) {
                        header "\(bridgingHeaderName)"
                        export *
                    }
                """
            }

            configuration.buildSettings = settings
            return configuration
        }

        pifTarget.buildConfigurations = newConfigurations

        if let clangTarget = resolvedTarget.underlyingTarget as? ClangTarget {
            let package = descriptionPackage.graph.package(for: resolvedTarget)!
            addPublicHeaders(of: pifTarget, project: project, package: package, clangTarget: clangTarget)
        }

        addLinkSettings(of: pifTarget)
    }

    private func updateCommonSettings(of pifTarget: PIF.Target, for sdk: SDK) {
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

    private func collectPublicHeaders(of clangTarget: ClangTarget) -> Set<AbsolutePath> {
        let publicHeaders = clangTarget
            .headers
            .filter { $0.isDescendant(of: clangTarget.includeDir) }
        let notSymlinks = publicHeaders.filter { !fileSystem.isSymlink($0) }
        let symlinks = publicHeaders.filter { !fileSystem.isSymlink($0) }

        // Sometimes, public headers include a file and its symlink both.
        // This situation raises a duplication error
        // So duplicated symlinks have to be omitted
        let notDuplicatedSymlinks = symlinks.filter { path in
            notSymlinks.allSatisfy { FileManager.default.contentsEqual(atPath: path.pathString, andPath: $0.pathString) }
        }

        return Set(notSymlinks + notDuplicatedSymlinks)
    }

    private func guid(for pifTarget: PIF.Target, _ suffixes: String...) -> String {
        "GUID::SCIPIO::\(pifTarget.name)::" + suffixes.joined(separator: "::")
    }

    private func addPublicHeaders(of pifTarget: PIF.Target, project: PIF.Project, package: ResolvedPackage, clangTarget: ClangTarget) {
        let packageRootDir = package.path
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
            guid: guid(for: pifTarget, "GROUPS", "HEADERS"),
            path: includeDir.relative(to: targetRootDir).pathString,
            sourceTree: .group,
            children: []
        )
        targetGroup.children.append(publicHeadersGroup)

        let headers = collectPublicHeaders(of: clangTarget)
        let fileReference = headers.enumerated().map { (index, headerPath) in
            let relativePath = headerPath.relative(to: includeDir)
            return PIF.FileReference(
                guid: guid(for: pifTarget, "HEADERS_FILE_REFERENCE_\(index)"),
                path: relativePath.pathString,
                sourceTree: .group
            )
        }

        fileReference.forEach { publicHeadersGroup.children.append($0) }

        let buildFiles = fileReference.enumerated().map { (index, reference) in
            PIF.BuildFile(
                guid: guid(for: pifTarget, "HEADERS_BUILD_FILE_\(index)"),
                file: reference,
                platformFilters: [],
                headerVisibility: .public
            )
        }

        let buildPhase = fetchBuildPhase(of: PIF.HeadersBuildPhase.self, in: pifTarget) ?? PIF.HeadersBuildPhase(
            guid: guid(for: pifTarget, "HEADERS_BUILD_PHASE"),
            buildFiles: []
        )
        buildPhase.buildFiles.append(contentsOf: buildFiles)
    }

    private func addLinkSettings(of pifTarget: PIF.Target) {
        let buildFiles = pifTarget.dependencies.enumerated().map { (index, dependency) in
            PIF.BuildFile(guid: guid(for: pifTarget, "FRAMEWORKS_BUILD_FILE_\(index)"),
                          targetGUID: dependency.targetGUID,
                          platformFilters: dependency.platformFilters)
        }

        let buildPhase = fetchBuildPhase(of: PIF.FrameworksBuildPhase.self, in: pifTarget) ?? PIF.FrameworksBuildPhase(
            guid: guid(for: pifTarget, "FRAMEWORKS_BUILD_PHASE"),
            buildFiles: []
        )
        buildPhase.buildFiles.append(contentsOf: buildFiles)
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
