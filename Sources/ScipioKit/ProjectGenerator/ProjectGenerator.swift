import Foundation
import PackageGraph
import XcodeProj
import AEXML
import struct TSCBasic.AbsolutePath
import struct TSCBasic.RelativePath
import var TSCBasic.localFileSystem
import PackageModel
import Basics
import PathKit

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

class ProjectGenerator {
    private let package: Package
    private let pbxProj: PBXProj
    private let fileSystem: any FileSystem

    private let isDebugSymbolsEmbedded: Bool
    private let frameworkType: FrameworkType

    init(
        package: Package,
        isDebugSymbolsEmbedded: Bool,
        frameworkType: FrameworkType,
        fileSystem: any FileSystem = localFileSystem
    ) {
        self.package = package
        self.isDebugSymbolsEmbedded = isDebugSymbolsEmbedded
        self.frameworkType = frameworkType
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
                defaultConfigurationName: "Debug", // TODO
                defaultConfigurationIsVisible: true
            )
        )
        let rootObject = addObject(
            PBXProject(
                name: "GeneratedProject",
                buildConfigurationList: buildConfigurationList,
                compatibilityVersion: "Xcode 11.0",
                mainGroup: mainGroup
            )
        )
        pbxProj.rootObject = rootObject
    }

    struct Result {
    }

    enum Error: LocalizedError {
        case invalidPackage
        case notSupported(PackageModel.Target.Kind)
        case unknownError
    }

    @discardableResult
    private func addObject<T: PBXObject>(_ object: T, context: String? = nil) -> T {
        pbxProj.add(object: object)
        object.context = context
        return object
    }

    private var sourceRootPath: URL? {
        guard let sourceRoot = package.graph.rootPackages.first?.path else {
            return nil
        }
        return URL(fileURLWithPath: sourceRoot.pathString)
    }

    @discardableResult
    func generate() throws -> Result {
        let projectPath = package.projectPath
        let parentDirectoryPath = package.projectPath.deletingLastPathComponent()

        preparePBXProj()

        guard let sourceRootDir = package.graph.rootPackages.first?.path else {
            throw Error.invalidPackage
        }
        pbxProj.rootObject?.projectDirPath = URL(fileURLWithPath: sourceRootDir.pathString, relativeTo: parentDirectoryPath).path

        guard let mainGroup = pbxProj.rootObject?.mainGroup else {
            throw Error.unknownError
        }

        // Dependencies
        let externalPackages = package.graph.packages.filter({ !package.graph.rootPackages.contains($0) })
        if !externalPackages.isEmpty {
            let dependenciesGroup = addObject(
                PBXGroup(sourceTree: .group,
                         name: "Dependencies",
                         path: nil)
            )
            mainGroup.addChild(dependenciesGroup)

            for package in externalPackages {
                let targets = package.targets.filter { $0.type != .test }
                try createSources(for: targets, in: dependenciesGroup)
            }
        }

        // TODO Resources

        // Products
        let productGroup = addObject(
            PBXGroup(
                sourceTree: .buildProductsDir,
                name: "Products",
                path: nil
            )
        )
        pbxProj.rootObject?.productsGroup = productGroup

        try generateTargets()

        let projectFile = XcodeProj(workspace: .init(),
                                    pbxproj: pbxProj)
        try projectFile.write(pathString: projectPath.path, override: true)

        return .init()
    }

    private func generateTargets() throws {
        // First, generate all targets
        let targetsToGenerate = package.graph.reachableTargets
            .filter { $0.type != .systemModule }
            .filter { $0.type != .test } // Scipio doesn't care test targets
            .sorted { $0.name < $1.name }
        let xcodeTargets: [ResolvedTarget: PBXTarget] = try targetsToGenerate.reduce(into: [:]) { targets, target in
            let xcodeTarget = addObject(
                try makeTarget(for: target)
            )
            targets[target] = xcodeTarget
        }
        xcodeTargets.values.forEach { self.pbxProj.rootObject?.targets.append($0) }

        // Make LinkPhase for each Xcode targets
        for (target, xcodeTarget) in xcodeTargets {
            let dependsTargets = try target.recursiveDependencies().compactMap { value in
                if case .target(let dependency, _) = value {
                    return (xcodeTargets[dependency])
                }
                return nil
            }
            xcodeTarget.dependencies = dependsTargets.map { target in
                addObject(PBXTargetDependency(target: target))
            }

            let linkReferences: [PBXBuildFile]
            if target.type == .library {
                linkReferences = dependsTargets.map { dependency in
                    addObject(PBXBuildFile(file: dependency.product))
                }
            } else {
                linkReferences = []
            }

            let linkPhase = addObject(
                PBXFrameworksBuildPhase(files: linkReferences)
            )
            xcodeTarget.buildPhases.append(linkPhase)
        }
    }

    private func makeTarget(for target: ResolvedTarget) throws -> PBXNativeTarget {
        let targetSettingsGenerator = TargetBuildSettingsGenerator(
            package: package,
            isDebugSymbolsEmbedded: isDebugSymbolsEmbedded,
            isStaticFramework: frameworkType == .static
        )

        let productType: PBXProductType
        switch target.type {
        case .executable, .snippet:
            productType = .commandLineTool
        case .library:
            productType = .framework
        case .test:
            productType = .unitTestBundle
        case .binary, .systemModule, .plugin:
            throw Error.notSupported(target.type)
        }

        // Generate Info.plist
        let plistPath = package.projectPath.appendingPathComponent(target.infoPlistFileName)
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
                sourceRoot: .init("."),
                validatePresence: false
            )
        } else {
            productRef = nil
        }

        guard let sourceRootPath = sourceRootPath else {
            throw Error.unknownError
        }

        let fileReferences = try target.sources.paths.map { sourcePath in
            let directoryPath = URL(fileURLWithPath: sourcePath.pathString).deletingLastPathComponent()

            let group = try group(for: directoryPath)
            let relativePath = URL(fileURLWithPath: sourcePath.pathString, relativeTo: sourceRootPath)
            return try group.addFile(
                at: Path(relativePath.path),
                sourceTree: .sourceRoot,
                sourceRoot: Path(sourceRootPath.path)
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

        // TODO : Add the `include` group for a library C language target.
        // TODO : modulemaps related settings

        return PBXNativeTarget(name: target.c99name,
                               buildConfigurationList: buildConfigurationList,
                               buildPhases: [compilePhase],
                               product: productRef,
                               productType: productType)
    }

    private func applyClangTargetSpecificSettings(for target: ClangTarget) {
        let includeDir = target.includeDir
    }

    private func createSources(for targets: [ResolvedTarget], in parentGroup: PBXGroup) throws {
        for target in targets {
            let sourceRoot = target.sources.root
            let targetGroup = addObject(
                PBXGroup(
                    children: [],
                    sourceTree: .group,
                    name: target.name,
                    path: sourceRoot.pathString
                )
            )
            parentGroup.addChild(targetGroup)

            for sourcePath in target.sources.paths {
                let url = URL(fileURLWithPath: sourcePath.pathString)
                let group = try group(for: url)
            }
        }
    }

    private func group(for path: URL) throws -> PBXGroup {
        guard let sourceRoot = sourceRootPath else {
            throw Error.invalidPackage
        }

        if path == sourceRoot {
            return pbxProj.rootObject!.mainGroup
        } else {
            let groupName = path.lastPathComponent
            let parentDir = path.deletingLastPathComponent()
            let parentGroup = try group(for: parentDir)
            if let existingGroup = parentGroup.group(named: groupName) {
                return existingGroup
            } else {
                return try parentGroup.addGroup(named: groupName).first!
            }
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
}
