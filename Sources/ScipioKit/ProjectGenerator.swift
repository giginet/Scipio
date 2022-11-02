import Foundation
import XcodeProj
import struct TSCBasic.AbsolutePath
import var TSCBasic.localFileSystem
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
    private let fileSystem: any FileSystem

    init(fileSystem: any FileSystem = localFileSystem) {
        self.fileSystem = fileSystem
    }

    struct Result {
    }

    enum Error: LocalizedError {
        case invalidPackage
    }

    @discardableResult
    func generate(
        for package: Package,
        embedDebugSymbols isDebugSymbolsEmbedded: Bool,
        frameworkType: FrameworkType
    ) throws -> Result {
        let projectPath = package.projectPath
        let parentDirectoryPath = package.projectPath.deletingLastPathComponent()

        let project = try XcodeProj(pathString: projectPath.path)

        guard let sourceRootDir = package.graph.rootPackages.first?.path else {
            throw Error.invalidPackage
        }
        project.pbxproj.rootObject?.projectDirPath = URL(fileURLWithPath: sourceRootDir.pathString, relativeTo: parentDirectoryPath).path

        // TODO setting

        try project.write(pathString: projectPath.path, override: true)

        return .init()
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
