import Foundation
import PackageGraph
import XcodeProj
import AEXML
import struct TSCBasic.AbsolutePath
import struct TSCBasic.RelativePath
import var TSCBasic.localFileSystem
import Basics
import PathKit

struct XCConfigValue {
    let rawString: String
}

extension XCConfigValue: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: BooleanLiteralType) {
        self.rawString = value ? "YES" : "NO"
    }
}

extension XCConfigValue: ExpressibleByStringLiteral {
    init(stringLiteral value: StringLiteralType) {
        self.rawString = value
    }
}

struct XCConfigEncoder {
    func generate(configs: [String: XCConfigValue]) -> Data {
        configs
            .sorted { $0.key < $1.key }
            .map { pair -> String in
                "\(pair.key) = \(pair.value.rawString)"
             }
             .joined(separator: "\n")
             .data(using: .utf8)!
    }
}

struct ProjectGenerator {
    private let pbxProj: PBXProj
    private let fileSystem: any FileSystem

    init(fileSystem: any FileSystem = localFileSystem) {
        self.pbxProj = .init()
        self.fileSystem = fileSystem
    }

    struct Result {
    }

    enum Error: LocalizedError {
        case invalidPackage
        case unknownError
    }

    @discardableResult
    private func addObject<T: PBXObject>(_ object: T, context: String? = nil) -> T {
        pbxProj.add(object: object)
        object.context = context
        return object
    }

    private func preparePBXProj() {
        let mainGroup = addObject(
            PBXGroup(
                children: [],
                sourceTree: .group
            )
        )

        let debugConfiguration = addObject(
            XCBuildConfiguration(name: "Debug")
        )

        let buildConfigurationList = addObject(
            XCConfigurationList(
                buildConfigurations: [
                    debugConfiguration
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

    @discardableResult
    func generate(
        for package: Package,
        embedDebugSymbols isDebugSymbolsEmbedded: Bool,
        frameworkType: FrameworkType
    ) throws -> Result {
        let projectPath = package.projectPath
        let parentDirectoryPath = package.projectPath.deletingLastPathComponent()

        preparePBXProj()

        guard let sourceRootDir = package.graph.rootPackages.first?.path else {
            throw Error.invalidPackage
        }
        pbxProj.rootObject?.projectDirPath = URL(fileURLWithPath: sourceRootDir.pathString, relativeTo: parentDirectoryPath).path

        applyBuildSettings()

        let packagesByTarget = package.graph.packages.reduce(into: [:]) { dict, package in
            for target in package.targets {
                dict[target] = package
            }
        }

        let packagesByProduct = package.graph.packages.reduce(into: [:]) { dict, package in
            for product in package.products {
                dict[product] = package
            }
        }

        if let targets = package.graph.rootPackages.first?.targets {
            let targetsForSources = targets.filter { $0.type != .test }
            try createSources(
                for: targetsForSources,
                in: pbxProj.rootObject!.mainGroup
            )
        }

        let projectFile = XcodeProj(workspace: .init(),
                                    pbxproj: pbxProj)
        try projectFile.write(pathString: projectPath.path, override: true)

        return .init()
    }

    private func applyBuildSettings() {
        guard let defaultConfiguration = pbxProj.buildConfigurations.first else {
            return
        }
        defaultConfiguration.baseConfiguration // TODO
    }

    private func createSources(for targets: [ResolvedTarget], in parentGroup: PBXGroup) throws {
        let sourceGroup = addObject(
            PBXGroup(
                sourceTree: .sourceRoot,
                name: "Sources",
                path: nil
            )
        )
        parentGroup.addChild(sourceGroup)

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
            sourceGroup.addChild(targetGroup)

            for sourcePath in target.sources.paths {
                let relativePath = sourcePath.relative(to: sourceRoot)
                let dirPath = RelativePath(relativePath.dirname)
                let group = try createIntermediateGroupsIfNeeded(of: dirPath, from: targetGroup)
                try group.addFile(at: sourcePath.toPath(),
                                  sourceRoot: sourcePath.relative(to: sourceRoot).toPath())
            }
        }
    }

    private func createIntermediateGroupsIfNeeded(of relativePath: RelativePath, from rootGroup: PBXGroup) throws -> PBXGroup {
        var dirs = relativePath.components
        var currentGroup: PBXGroup = rootGroup
        if dirs.count <= 1 {
            return currentGroup
        }
        while !dirs.isEmpty {
            guard let nextDir = dirs.first else {
                break
            }
            let nextGroup = try createGroupIfNeeded(named: nextDir, at: currentGroup)
            currentGroup = nextGroup
            dirs.removeFirst()
        }
        return currentGroup
    }

    private func createGroupIfNeeded(named groupName: String, at group: PBXGroup) throws -> PBXGroup {
        if let existingGroup = group.group(named: groupName) {
            return existingGroup
        } else {
            return try group.addGroup(named: groupName).first!
        }
    }

    private func makeXCConfigData(isDebugSymbolsEmbedded: Bool, isStaticFramework: Bool) -> Data {
        var configs: [String: XCConfigValue] = [
            "BUILD_LIBRARY_FOR_DISTRIBUTION": true,
        ]

        if isDebugSymbolsEmbedded {
            configs["DEBUG_INFORMATION_FORMAT"] = "dwarf-with-dsym"
        }

        if isStaticFramework {
            configs["MACH_O_TYPE"] = "staticlib"
        }

        let encoder = XCConfigEncoder()
        return encoder.generate(configs: configs)
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
