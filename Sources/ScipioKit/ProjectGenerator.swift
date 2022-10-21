import Foundation
import Xcodeproj
import TSCBasic
import Basics

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
    private let fileSystem: any ScipioKit.FileSystem

    init(fileSystem: any ScipioKit.FileSystem = ScipioKit.localFileSystem) {
        self.fileSystem = fileSystem
    }

    struct Result {
        var project: Xcode.Project
        var projectPath: AbsolutePath
    }

    @discardableResult
    func generate(
        for package: Package,
        embedDebugSymbols isDebugSymbolsEmbedded: Bool,
        frameworkType: FrameworkType
    ) throws -> Result {
        let projectPath = package.projectPath

        let project = try pbxproj(
            xcodeprojPath: projectPath,
            graph: package.graph,
            extraDirs: [],
            extraFiles: [],
            options: .init(useLegacySchemeGenerator: false),
            fileSystem: TSCBasic.localFileSystem,
            observabilityScope: observabilitySystem.topScope)

        let distributionXCConfigPath = package.workspaceDirectory.appending(component: "Distribution.xcconfig")

        let isStaticFramework = frameworkType == .static
        let xcConfigData = makeXCConfigData(
            isDebugSymbolsEmbedded: isDebugSymbolsEmbedded,
            isStaticFramework: isStaticFramework
        )
        fileSystem.write(xcConfigData, to: distributionXCConfigPath.asURL)

        let group = createOrGetConfigsGroup(project: project)
        let reference = group.addFileReference(
            path: distributionXCConfigPath.pathString,
            name: distributionXCConfigPath.basename
        )

        for target in project.frameworkTargets {
            target.buildSettings.xcconfigFileRef = reference
        }

        try fileSystem.createDirectory(projectPath.asURL, recursive: true)

        for target in project.frameworkTargets {
            let name = "\(target.name.spm_mangledToC99ExtendedIdentifier())_Info.plist"
            let path = projectPath.asURL.appendingPathComponent(name)
            fileSystem.write(infoPlist.data(using: .utf8)!, to: path)
        }

        let pbxprojPath = projectPath.appending(component: "project.pbxproj")
        // Serialize the project model we created to a plist, and return
        // its string description.
        if let plist = try? project.generatePlist() {
            let str = "// !$*UTF8*$!\n" + plist.description
            fileSystem.write(str.data(using: .utf8)!, to: pbxprojPath.asURL)
        }

        return .init(project: project, projectPath: projectPath)
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

    private func createOrGetConfigsGroup(project: Xcode.Project) -> Xcode.Group {
        let name = "Configs"

        if let group = project.mainGroup.subitems.lazy.compactMap({ $0 as? Xcode.Group }).first(where: { $0.name == name }) {
            return group
        }

        return project.mainGroup.addGroup(path: "", name: name)
    }
}

extension Xcode.Project {
    fileprivate var frameworkTargets: [Xcode.Target] {
        targets.filter { $0.productType == .framework }
    }
}
