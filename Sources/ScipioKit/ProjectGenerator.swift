import Foundation
import PackageGraph
import class XcodeProj.PBXProject
import class XcodeProj.XcodeProj
import class XcodeProj.PBXGroup
import AEXML
import struct TSCBasic.AbsolutePath
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
    private let fileSystem: any FileSystem

    init(fileSystem: any FileSystem = localFileSystem) {
        self.fileSystem = fileSystem
    }

    struct Result {
    }

    enum Error: LocalizedError {
        case invalidPackage
        case unknownError
    }

    @discardableResult
    func generate(
        for package: Package,
        embedDebugSymbols isDebugSymbolsEmbedded: Bool,
        frameworkType: FrameworkType
    ) throws -> Result {
        let projectPath = package.projectPath
        let parentDirectoryPath = package.projectPath.deletingLastPathComponent()

        let projectFile = try XcodeProj(pathString: projectPath.path)

        guard let project = projectFile.pbxproj.projects.first else {
            throw Error.unknownError
        }

        guard let sourceRootDir = package.graph.rootPackages.first?.path else {
            throw Error.invalidPackage
        }
        projectFile.pbxproj.rootObject?.projectDirPath = URL(fileURLWithPath: sourceRootDir.pathString, relativeTo: parentDirectoryPath).path

        applyBuildSettings(for: project)

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

        try projectFile.write(pathString: projectPath.path, override: true)

        return .init()
    }

    private func applyBuildSettings(for project: PBXProject) {
        guard let defaultConfigurationName = project.buildConfigurationList.defaultConfigurationName,
              let baseConfiguration = project.buildConfigurationList.configuration(name: defaultConfigurationName)?.buildSettings else {
            return
        }
        baseConfiguration // TODO
    }

    private func createGroup(named groupName: String, for targets: [ResolvedTarget], in parentGroup: PBXGroup) throws {
        guard let sourceGroup = try parentGroup.addGroup(named: groupName).first else {
            return
        }
        for target in targets {
            guard let targetGroup = try sourceGroup.addGroup(named: target.name).first else {
                continue
            }
            let sourceRoot = target.sources.root
            for source in target.sources.paths {
                try targetGroup.addFile(at: .init(source.pathString),
                                        sourceRoot: sourceRoot.toPath())
            }
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
