import Foundation
import PackageGraph
import XcodeProj
import AEXML
import struct TSCBasic.AbsolutePath
import struct TSCBasic.RelativePath
import var TSCBasic.localFileSystem
import func TSCBasic.walk
import protocol TSCBasic.FileSystem
import PackageLoading
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
        mainGroup.addChild(productGroup)

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

        try generateAllTargets()

        let projectFile = XcodeProj(workspace: .init(), pbxproj: pbxProj)
        try projectFile.write(pathString: projectPath.path, override: true)
    }

    private func generateAllTargets() throws {
        // First, generate PBXTargets of all libraries
        let targetsToGenerate = package.graph.reachableTargets
            .filter { $0.type == .library }
            .sorted { $0.name < $1.name }

        let xcodeTargets: [ResolvedTarget: GeneratedTargetsContainer] = try targetsToGenerate.reduce(into: [:]) { targets, target in
            targets[target] = try makeTargets(for: target)
        }
        for container in xcodeTargets.values {
            container.targets.forEach { target in
                addObject(target)
                self.pbxProj.rootObject?.targets.append(target)
            }
        }

        // Generate ModuleMaps for Clang targets
        let moduleMaps: [ResolvedTarget: AbsolutePath] = try xcodeTargets.reduce(into: [:]) { (collection, tuple) in
            let (target, xcodeTarget) = tuple
            if let clangTarget = target.underlyingTarget as? ClangTarget,
               let moduleMapPath = try applyClangTargetSpecificSettings(
                for: clangTarget,
                xcodeTarget: xcodeTarget.frameworkTarget
               ).moduleMapPath {
                collection[target] = moduleMapPath
            }
        }

        // Register dependencies for each Xcode targets
        for (target, xcodeTargetContainer) in xcodeTargets {
            let frameworkTarget = xcodeTargetContainer.frameworkTarget

            // Add a resource target and Package dependencies as target dependencies
            let dependsTargets = try target.recursiveDependencies().compactMap { dependency in
                if case .target(let resolvedTarget, _) = dependency {
                    return resolvedTarget
                }
                return nil
            }
            let resourceTargets = [xcodeTargetContainer.resourceBundleTarget].compactMap { $0 }

            let dependencyTargets = dependsTargets
                .compactMap { xcodeTargets[$0]?.frameworkTarget }

            frameworkTarget.dependencies = (resourceTargets + dependencyTargets)
                .map { target in
                    addObject(PBXTargetDependency(target: target))
                }

            // Add Resource bundle to Resources Phase
            if let resourceTarget = xcodeTargetContainer.resourceBundleTarget {
                let bundleFileReference = addObject(
                    PBXBuildFile(file: resourceTarget.product)
                )
                let resourcePhase = addObject(
                    PBXResourcesBuildPhase(files: [bundleFileReference])
                )
                frameworkTarget.buildPhases.append(resourcePhase)
            }

            // Make Link Phase
            let linkReferences: [PBXBuildFile]
            if target.type == .library {
                linkReferences = dependsTargets
                    .compactMap { xcodeTargets[$0]?.frameworkTarget }
                    .map { dependency in
                        addObject(PBXBuildFile(file: dependency.product))
                    }
            } else {
                linkReferences = []
            }

            let linkPhase = addObject(
                PBXFrameworksBuildPhase(files: linkReferences)
            )
            frameworkTarget.buildPhases.append(linkPhase)

            // Add -fmodule-map-file for Swift targets
            if target.isSwiftTarget {
                for dependency in dependsTargets {
                    guard let moduleMapPath = moduleMaps[dependency] else { continue }
                    let relativePath = moduleMapPath.relative(to: sourceRoot!)
                    frameworkTarget.buildConfigurationList?.buildConfigurations.forEach { configuration in
                        configuration.buildSettings = configuration.buildSettings.appending(
                            "OTHER_SWIFT_FLAGS",
                            values: "-Xcc", "-fmodule-map-file=$(SRCROOT)/\(relativePath.pathString)"
                        )
                    }
                }
            }
        }
    }

    private struct GeneratedTargetsContainer {
        var target: ResolvedTarget
        var frameworkTarget: PBXNativeTarget
        var resourceBundleTarget: PBXNativeTarget?

        var targets: Set<PBXNativeTarget> {
            Set([frameworkTarget, resourceBundleTarget].compactMap { $0 })
        }
    }

    private func makeTargets(
        for target: ResolvedTarget
    ) throws -> GeneratedTargetsContainer {
        let targetSettingsGenerator = TargetBuildSettingsGenerator(
            package: package,
            platforms: Set(buildOptions.sdks),
            isDebugSymbolsEmbedded: buildOptions.isDebugSymbolsEmbedded,
            isStaticFramework: buildOptions.frameworkType == .static,
            isSimulatorSupported: true
        )

        guard let productType = target.xcodeProductType else {
            throw Error.unsupportedTarget(targetName: target.name, kind: target.type)
        }

        // Generate Info.plist
        let plistPath = package.buildDirectory.appendingPathComponent(target.infoPlistFileName)
        let plistData = InfoPlistGenerator.generate(bundleType: .framework)
        try fileSystem.writeFileContents(plistPath.absolutePath, data: plistData)

        let buildConfigurationList = addObject(
            XCConfigurationList(buildConfigurations: [
                addObject(try targetSettingsGenerator.generate(for: target, configuration: .debug, infoPlistPath: plistPath)),
                addObject(try targetSettingsGenerator.generate(for: target, configuration: .release, infoPlistPath: plistPath)),
            ])
        )

        // Make Resource target if needed (returns nil if not necessary)
        let resourceTarget = try makeResourceTarget(for: target)

        let productRef: PBXFileReference? = try? pbxProj.rootObject?
            .productsGroup?
            .addFile(
                at: target.productPath.toPath(),
                sourceTree: .buildProductsDir,
                sourceRoot: target.sources.root.toPath(),
                validatePresence: false
            )

        guard let sourceRoot = sourceRoot,
              let mainGroup = pbxProj.rootObject?.mainGroup else {
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

        // Inject a bundle accessor
        let additionalFiles: [PBXFileReference]
        if let resourceTarget {
            let bundleAccessorGenerator = BundleAccessorGenerator(package: package)
            let accessorPath = try bundleAccessorGenerator.generate(resourceBundleName: resourceTarget.name)
            let bundleAccessorReference = addObject(
                try targetGroup.addFile(at: Path(accessorPath.path), sourceRoot: sourceRoot.toPath())
            )
            additionalFiles = [bundleAccessorReference]
        } else {
            additionalFiles = []
        }

        let buildFiles: [PBXBuildFile] = (fileReferences + additionalFiles).map { reference in
            addObject(PBXBuildFile(file: reference))
        }

        let compilePhase = addObject(
            PBXSourcesBuildPhase(files: buildFiles)
        )

        let frameworkTarget = PBXNativeTarget(name: target.c99name,
                                              buildConfigurationList: buildConfigurationList,
                                              buildPhases: [compilePhase],
                                              product: productRef,
                                              productType: productType)

        return .init(target: target, frameworkTarget: frameworkTarget, resourceBundleTarget: resourceTarget)
    }

    private func generateBundleAccessor(
        for resourceTarget: PBXNativeTarget,
        targetGroup: PBXGroup,
        sourceRoot: AbsolutePath
    ) throws -> PBXFileReference {
        let bundleAccessorGenerator = BundleAccessorGenerator(package: package)
        let accessorPath = try bundleAccessorGenerator.generate(resourceBundleName: resourceTarget.name)
        let bundleAccessorReference = addObject(
            try targetGroup.addFile(at: Path(accessorPath.path), sourceRoot: sourceRoot.toPath())
        )
        return bundleAccessorReference
    }

    private func makeResourceTarget(for target: ResolvedTarget) throws -> PBXNativeTarget? {
        guard let resolvedPackage = package.graph.package(for: target) else {
            throw Error.unknownError
        }

        guard fileSystem.exists(target.resourceDir.absolutePath) else {
            return nil
        }

        guard let mainGroup = pbxProj.rootObject?.mainGroup else {
            throw Error.unknownError
        }

        let resourceTargetName = "\(target.c99name)-Resources"
        let resourceTargetGroup = createOrGetGroup(
            named: resourceTargetName,
            in: mainGroup,
            path: try AbsolutePath(validating: target.resourceDir.path))

        let collector = ResourceCollector(
            package: resolvedPackage,
            target: target
        )
        let resources = try collector.collect()

        let resourcesReferences: [PBXFileReference] = try resources.map { resource in
            let filePath = target.resourceDir.appendingPathComponent(resource.destination.pathString)
            let file = try resourceTargetGroup.addFile(at: Path(filePath.path), sourceRoot: Path(target.resourceDir.path))
            return addObject(file)
        }

        let buildFiles = resourcesReferences.map { addObject(PBXBuildFile(file: $0)) }

        let resourcePhase = addObject(PBXResourcesBuildPhase(files: buildFiles))

        // Generate Info.plist
        let plistFileName = "\(resourceTargetName)_Info.plist"
        let plistPath = package.buildDirectory.appendingPathComponent(plistFileName)
        let plistData = InfoPlistGenerator.generate(bundleType: .bundle)
        try fileSystem.writeFileContents(plistPath.absolutePath, data: plistData)

        let builder = ResourceBundleSettingsBuilder()
        let configurations = [.debug, .release].map { (configuration: BuildConfiguration) in
            addObject(
                builder.generate(
                    for: target,
                    configuration: configuration,
                    infoPlistPath: plistPath,
                    isSimulatorSupported: true
                )
            )
        }
        let configurationList = addObject(
            XCConfigurationList(
                buildConfigurations: configurations,
                defaultConfigurationName: "Debug",
                defaultConfigurationIsVisible: true
            )
        )

        let productRef: PBXFileReference? = try? pbxProj.rootObject?
            .productsGroup?
            .addFile(
                at: Path("\(resourceTargetName).bundle"),
                sourceTree: .buildProductsDir,
                sourceRoot: Path(target.resourceDir.path),
                validatePresence: false
            )

        return PBXNativeTarget(
            name: resourceTargetName,
            buildConfigurationList: configurationList,
            buildPhases: [resourcePhase],
            product: productRef,
            productType: .bundle
        )
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
        let headerFileRefs: [PBXFileReference] = try headerFiles.map { header in
            let headerFileGroup = try self.group(
                for: header.parentDirectory,
                parentGroup: targetGroup,
                sourceRoot: clangTarget.sources.root
            )
            return try headerFileGroup.addFile(at: header.toPath(), sourceRoot: clangTarget.path.toPath())
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
            // If modulemap path is specified, use this
            return path
        } else if hasUmbrellaHeader {
            // If package contains umbrella headers, it generates modulemap using Xcode
            let files = includeFileRefs.map { fileRef in
                addObject(PBXBuildFile(file: fileRef, settings: ["ATTRIBUTES": ["Public"]]))
            }
            let headerPhase = addObject(
                PBXHeadersBuildPhase(files: files)
            )

            xcodeTarget.buildPhases.append(headerPhase)

            if let allConfigurations = xcodeTarget.buildConfigurationList?.buildConfigurations {
                for configuration in allConfigurations {
                    configuration.buildSettings["CLANG_ENABLE_MODULES"] = true
                    configuration.buildSettings["DEFINES_MODULE"] = true
                }
            }

            return nil
        } else if let generatedModuleMapType = clangTarget.moduleMapType.generatedModuleMapType {
            // If package has modulemap type, it generates new modulemap
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

    fileprivate var resourceDir: URL {
        underlyingTarget.path.appending(component: "Resources").asURL
    }

    fileprivate var isSwiftTarget: Bool {
        underlyingTarget is SwiftTarget
    }
}
