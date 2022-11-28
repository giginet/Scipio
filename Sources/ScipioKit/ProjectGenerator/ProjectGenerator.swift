import Foundation
import PackageGraph
import XcodeProj
import AEXML
import struct TSCBasic.AbsolutePath
import struct TSCBasic.RelativePath
import var TSCBasic.localFileSystem
import func TSCBasic.walk
import struct PackageLoading.ModuleMapGenerator
import enum PackageLoading.GeneratedModuleMapType
import PackageModel
import Basics
import PathKit

class ProjectGenerator {
    private let package: Package
    private let pbxProj: PBXProj
    private let fileSystem: any FileSystem

    private let buildOptions: BuildOptions

    init(
        package: Package,
        buildOptions: BuildOptions,
        fileSystem: any FileSystem = localFileSystem
    ) {
        self.package = package
        self.buildOptions = buildOptions
        self.pbxProj = .init()
        self.fileSystem = fileSystem
    }

    private func preparePBXProj() {
        let mainGroup = addObject(
            PBXGroup(
                children: [],
                sourceTree: .group
            )
        )

        let buildSettingsGenerator = ProjectBuildSettingsGenerator()

        let debugConfiguration = addObject(
            buildSettingsGenerator.generate(configuration: .debug)
        )
        let releaseConfiguration = addObject(
            buildSettingsGenerator.generate(configuration: .release)
        )

        let buildConfigurationList = addObject(
            XCConfigurationList(
                buildConfigurations: [
                    debugConfiguration,
                    releaseConfiguration,
                ],
                defaultConfigurationName: buildOptions.buildConfiguration.settingsValue,
                defaultConfigurationIsVisible: true
            )
        )

        let productGroup = addObject(
            PBXGroup(
                sourceTree: .buildProductsDir,
                name: "Products",
                path: nil
            )
        )

        let rootObject = addObject(
            PBXProject(
                name: package.manifest.displayName,
                buildConfigurationList: buildConfigurationList,
                compatibilityVersion: "Xcode 11.0",
                mainGroup: mainGroup,
                productsGroup: productGroup
            )
        )
        pbxProj.rootObject = rootObject

    }

    enum Error: LocalizedError {
        case invalidPackage(packageName: String)
        case unsupportedTarget(targetName: String, kind: PackageModel.Target.Kind)
        case localizationNotSupported(targetName: String)
        case unknownError

        var errorDescription: String? {
            switch self {
            case .invalidPackage(let packageName):
                return "\(packageName) is invalid package"
            case .unsupportedTarget(let targetName, let kind):
                return "\(targetName) is \(kind) but \(kind) is not supported yet"
            case .localizationNotSupported(let targetName):
                return "\(targetName) has localized resources but localized resources are not supported yet"
            case .unknownError:
                return "Unknown errors are occurred"
            }
        }
    }

    @discardableResult
    private func addObject<T: PBXObject>(_ object: T, context: String? = nil) -> T {
        pbxProj.add(object: object)
        object.context = context
        return object
    }

    private var sourceRoot: AbsolutePath? {
        return package.graph.rootPackages.first?.path
    }

    func generate() throws {
        let projectPath = package.projectPath
        let parentDirectoryPath = package.projectPath.deletingLastPathComponent()

        preparePBXProj()

        guard let sourceRootDir = package.graph.rootPackages.first?.path else {
            throw Error.invalidPackage(packageName: package.name)
        }
        pbxProj.rootObject?.projectDirPath = URL(fileURLWithPath: sourceRootDir.pathString, relativeTo: parentDirectoryPath).path

        try generateTargets()

        let projectFile = XcodeProj(workspace: .init(), pbxproj: pbxProj)
        try projectFile.write(pathString: projectPath.path, override: true)
    }

    private func generateTargets() throws {
        // First, generate PBXTargets of all libraries
        let targetsToGenerate = package.graph.reachableTargets
            .filter { $0.type == .library }
            .sorted { $0.name < $1.name }

        let xcodeTargets: [ResolvedTarget: PBXNativeTarget] = try targetsToGenerate.reduce(into: [:]) { targets, target in
            let xcodeTarget = addObject(
                try makeTarget(for: target)
            )
            targets[target] = xcodeTarget
        }
        xcodeTargets.values.forEach { self.pbxProj.rootObject?.targets.append($0) }

        // Generate ModuleMaps for Clang targets
        let moduleMaps: [ResolvedTarget: AbsolutePath] = try xcodeTargets.reduce(into: [:]) { (collection, tuple) in
            let (target, xcodeTarget) = tuple
            if let clangTarget = target.underlyingTarget as? ClangTarget {
                if let moduleMapPath = try applyClangTargetSpecificSettings(for: clangTarget, xcodeTarget: xcodeTarget).moduleMapPath {
                    collection[target] = moduleMapPath
                }
            }
        }

        // Make LinkPhase for each Xcode targets
        for (target, xcodeTarget) in xcodeTargets {
            let dependsTargets = try target.recursiveDependencies().compactMap { value in
                if case .target(let dependency, _) = value {
                    return dependency
                }
                return nil
            }
            xcodeTarget.dependencies = dependsTargets
                .compactMap { xcodeTargets[$0] }
                .map { target in
                    addObject(PBXTargetDependency(target: target))
                }

            let linkReferences: [PBXBuildFile]
            if target.type == .library {
                linkReferences = dependsTargets
                    .compactMap { xcodeTargets[$0] }
                    .map { dependency in
                        addObject(PBXBuildFile(file: dependency.product))
                    }
            } else {
                linkReferences = []
            }

            let linkPhase = addObject(
                PBXFrameworksBuildPhase(files: linkReferences)
            )
            xcodeTarget.buildPhases.append(linkPhase)

            // Add -fmodule-map-file for Swift targets
            let isSwiftTarget = target.underlyingTarget is SwiftTarget
            if isSwiftTarget {
                for dependency in dependsTargets {
                    guard let moduleMapPath = moduleMaps[dependency] else { continue }
                    let relativePath = moduleMapPath.relative(to: sourceRoot!)
                    xcodeTarget.buildConfigurationList?.buildConfigurations.forEach { configuration in
                        configuration.buildSettings = configuration.buildSettings.appending(
                            "OTHER_SWIFT_FLAGS",
                            values: "-Xcc", "-fmodule-map-file=$(SRCROOT)/\(relativePath.pathString)"
                        )
                    }
                }
            }
        }
    }

    private func makeTarget(for target: ResolvedTarget) throws -> PBXNativeTarget {
        let targetSettingsGenerator = TargetBuildSettingsGenerator(
            package: package,
            isDebugSymbolsEmbedded: buildOptions.isDebugSymbolsEmbedded,
            isStaticFramework: buildOptions.frameworkType == .static
        )

        guard let productType = target.xcodeProductType else {
            throw Error.unsupportedTarget(targetName: target.name, kind: target.type)
        }

        // Generate Info.plist
        let plistPath = package.buildDirectory.appendingPathComponent(target.infoPlistFileName)
        fileSystem.write(infoPlist.data(using: .utf8)!, to: plistPath)

        let buildConfigurationList = addObject(
            XCConfigurationList(buildConfigurations: [
                addObject(targetSettingsGenerator.generate(for: target, configuration: .debug, infoPlistPath: plistPath)),
                addObject(targetSettingsGenerator.generate(for: target, configuration: .release, infoPlistPath: plistPath)),
            ])
        )

        let productRef: PBXFileReference?
        if let productGroup = pbxProj.rootObject?.productsGroup {
            productRef = try productGroup.addFile(
                at: target.productPath.toPath(),
                sourceTree: .buildProductsDir,
                sourceRoot: target.sources.root.toPath(),
                validatePresence: false
            )
        } else {
            productRef = nil
        }

        guard let sourceRoot = sourceRoot else {
            throw Error.unknownError
        }

        guard let mainGroup = pbxProj.rootObject?.mainGroup else {
            throw Error.unknownError
        }

        let targetGroup = createOrGetGroup(named: target.name, in: mainGroup, path: target.sources.root)

        let fileReferences = try target.sources.paths.map { sourcePath in
            let group = try self.group(
                for: sourcePath.parentDirectory,
                parentGroup: targetGroup,
                sourceRoot: target.sources.root
            )
            return try group.addFile(
                at: sourcePath.toPath(),
                sourceTree: .sourceRoot,
                sourceRoot: sourceRoot.toPath()
            )
        }

        let buildFiles: [PBXBuildFile] = fileReferences.map { reference in
            return addObject(PBXBuildFile(file: reference))
        }

        let compilePhase = addObject(
            PBXSourcesBuildPhase(
                files: buildFiles
            )
        )

        if !target.underlyingTarget.resources.isEmpty {
            logger.warning(
            """
            🚧 \(target.name) has resources. However, resource support is currently partial yet.
            You can't use `Bundle.module` using Scipio
            """)
        }

        let resourcePhase = addObject(
            try makeResourcePhase(for: target, targetGroup: targetGroup)
        )

        // TODO generate resource accessor to support Bundle.module
        // https://github.com/apple/swift-package-manager/blob/29a16bc2dc0ef72b7044c1dc6236236e3d0120e0/Sources/Build/BuildPlan.swift#L806-L852

        return PBXNativeTarget(name: target.c99name,
                               buildConfigurationList: buildConfigurationList,
                               buildPhases: [compilePhase, resourcePhase],
                               product: productRef,
                               productType: productType)
    }

    private func makeResourcePhase(for target: ResolvedTarget, targetGroup: PBXGroup) throws -> PBXResourcesBuildPhase {
        guard let sourceRoot else {
            throw Error.invalidPackage(packageName: package.name)
        }

        let resourcesReferences: [PBXFileReference] = try target.underlyingTarget.resources.reduce([]) { lists, resource in
            let resourcesGroup = try targetGroup.addGroup(named: "Resources").first!

            switch resource.rule {
            case .process(let localization):
                guard localization == nil else {
                    throw Error.localizationNotSupported(targetName: target.name)
                }
            case .copy:
                break
            }

            let files = try walk(resource.path)
            return try files.map { file in
                return try resourcesGroup.addFile(at: file.toPath(), sourceRoot: sourceRoot.toPath())
            } + lists
        }

        let buildFiles = resourcesReferences.map { PBXBuildFile(file: $0) }

        return PBXResourcesBuildPhase(files: buildFiles)
    }

    private struct ClangTargetSettingResult {
        var moduleMapPath: AbsolutePath?
    }

    private func applyClangTargetSpecificSettings(for clangTarget: ClangTarget, xcodeTarget: PBXNativeTarget) throws -> ClangTargetSettingResult {
        guard let mainGroup = pbxProj.rootObject?.mainGroup else {
            throw Error.unknownError
        }
        let targetGroup = createOrGetGroup(named: clangTarget.name, in: mainGroup, path: clangTarget.sources.root)

        let includeDir = clangTarget.includeDir
        let headerFiles = try walk(includeDir).filter { $0.extension == "h" }
        var headerFileRefs: [PBXFileReference] = []
        for header in headerFiles {
            let headerFileGroup = try self.group(
                for: header.parentDirectory,
                parentGroup: targetGroup,
                sourceRoot: clangTarget.sources.root
            )
            let fileRef = try headerFileGroup.addFile(at: header.toPath(),
                                                      sourceRoot: clangTarget.path.toPath())
            headerFileRefs.append(fileRef)
        }
        let moduleMapPath = try prepareModuleMap(for: clangTarget, xcodeTarget: xcodeTarget, includeFileRefs: headerFileRefs)
        if let moduleMapPath {
            try targetGroup.addFile(at: moduleMapPath.toPath(),
                                    sourceRoot: includeDir.toPath())
        }
        return .init(moduleMapPath: moduleMapPath)
    }

    private func prepareModuleMap(
        for clangTarget: ClangTarget,
        xcodeTarget: PBXNativeTarget,
        includeFileRefs: [PBXFileReference]
    ) throws -> AbsolutePath? {
        let headerFiles = try walk(clangTarget.includeDir).filter { $0.extension == "h" }

        let hasUmbrellaHeader = headerFiles
            .map { $0.basenameWithoutExt }
            .contains(clangTarget.c99name)

        if case .custom(let path) = clangTarget.moduleMapType {
            return path
        } else if hasUmbrellaHeader {
            let files = includeFileRefs.map { fileRef in
                PBXBuildFile(file: fileRef, settings: ["ATTRIBUTES": "Public"])
            }
            let headerPhase = addObject(
                PBXHeadersBuildPhase(files: files)
            )

            xcodeTarget.buildPhases.append(headerPhase)
            return nil
        } else if let generatedModuleMapType = clangTarget.moduleMapType.generatedModuleMapType {
            let generatedModuleMapPath = try generateModuleMap(for: clangTarget, moduleMapType: generatedModuleMapType)
            return generatedModuleMapPath
        }
        return nil
    }

    private func generateModuleMap(for clangTarget: ClangTarget, moduleMapType: GeneratedModuleMapType) throws -> AbsolutePath {
        let fileSystem = TSCBasic.localFileSystem
        let moduleMapPath = try AbsolutePath(validating: package.projectPath.path)
            .appending(components: "GeneratedModuleMap", clangTarget.c99name, "module.modulemap")
        try fileSystem.createDirectory(moduleMapPath.parentDirectory, recursive: true)

        let moduleMapGenerator = ModuleMapGenerator(
            targetName: clangTarget.name,
            moduleName: clangTarget.c99name,
            publicHeadersDir: clangTarget.includeDir,
            fileSystem: fileSystem
        )
        try moduleMapGenerator.generateModuleMap(type: moduleMapType,
                                                 at: moduleMapPath)
        return moduleMapPath
    }
}

extension ProjectGenerator {
    /// Helper function to create or get group recursively
    fileprivate func group(
        for path: AbsolutePath,
        parentGroup: PBXGroup,
        sourceRoot: AbsolutePath
    ) throws -> PBXGroup {
        let relativePath = path.relative(to: sourceRoot)
        let pathComponents = relativePath.components.filter { $0 != "." }

        return pathComponents.reduce(parentGroup) { currentParentGroup, component in
            return createOrGetGroup(named: component, in: currentParentGroup, path: path)
        }
    }

    fileprivate func createOrGetGroup(named groupName: String, in parentGroup: PBXGroup, path: AbsolutePath) -> PBXGroup {
        if let existingGroup = parentGroup.group(named: groupName) {
            return existingGroup
        } else {
            let newGroup = addObject(
                PBXGroup(sourceTree: .group, name: groupName, path: path.pathString)
            )
            parentGroup.addChild(newGroup)
            return newGroup
        }
    }
}

extension AbsolutePath {
    fileprivate func toPath() -> PathKit.Path {
        .init(self.pathString)
    }
}

extension RelativePath {
    fileprivate func toPath() -> PathKit.Path {
        .init(self.pathString)
    }
}

extension PBXGroup {
    fileprivate func addChild(_ childGroup: PBXGroup) {
        childGroup.parent = self
        self.children.append(childGroup)
    }
}

extension ResolvedTarget {
    fileprivate var productPath: RelativePath {
        switch type {
        case .test:
            return RelativePath("\(c99name).xctest")
        case .library:
            return RelativePath("\(c99name).framework")
        case .executable, .snippet:
            return RelativePath(name)
        case .systemModule, .binary, .plugin:
            fatalError()
        }
    }

    fileprivate var infoPlistFileName: String {
        return "\(c99name)_Info.plist"
    }

    fileprivate var xcodeProductType: PBXProductType? {
        switch type {
        case .executable, .snippet:
            return .commandLineTool
        case .library:
            return .framework
        case .test:
            return .unitTestBundle
        case .binary, .systemModule, .plugin:
            return nil
        }
    }
}

private var infoPlist: String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0">
    <dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>CFBundleVersion</key>
    <string>$(CURRENT_PROJECT_VERSION)</string>
    <key>NSPrincipalClass</key>
    <string></string>
    </dict>
    </plist>
    """
}
