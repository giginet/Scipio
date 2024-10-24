import Foundation
import TSCBasic
import PackageGraph
import PackageModel

// A generator to generate modulemaps which are distributed in the XCFramework
struct FrameworkModuleMapGenerator {
    private struct Context {
        var resolvedTarget: ScipioResolvedModule
        var sdk: SDK
        var keepPublicHeadersStructure: Bool
    }

    private var packageLocator: any PackageLocator
    private var fileSystem: any FileSystem

    enum Error: LocalizedError {
        case unableToLoadCustomModuleMap(AbsolutePath)

        var errorDescription: String? {
            switch self {
            case .unableToLoadCustomModuleMap(let customModuleMapPath):
                return "Something went wrong to load \(customModuleMapPath.pathString)"
            }
        }
    }

    init(packageLocator: some PackageLocator, fileSystem: some FileSystem) {
        self.packageLocator = packageLocator
        self.fileSystem = fileSystem
    }

    func generate(
        resolvedTarget: ScipioResolvedModule,
        sdk: SDK,
        keepPublicHeadersStructure: Bool
    ) throws -> AbsolutePath? {
        let context = Context(
            resolvedTarget: resolvedTarget,
            sdk: sdk,
            keepPublicHeadersStructure: keepPublicHeadersStructure
        )

        if let clangTarget = resolvedTarget.underlying as? ScipioClangModule {
            switch clangTarget.moduleMapType {
            case .custom, .umbrellaHeader, .umbrellaDirectory:
                let path = try constructGeneratedModuleMapPath(context: context)
                try generateModuleMapFile(context: context, outputPath: path)
                return path
            case .none:
                return nil
            }
        } else {
            let path = try constructGeneratedModuleMapPath(context: context)
            try generateModuleMapFile(context: context, outputPath: path)
            return path
        }
    }

    private func generateModuleMapContents(context: Context) throws -> String {
        if let clangTarget = context.resolvedTarget.underlying as? ScipioClangModule {
            switch clangTarget.moduleMapType {
            case .custom(let customModuleMap):
                return try convertCustomModuleMapForFramework(customModuleMap.scipioAbsolutePath)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            case .umbrellaHeader(let headerPath):
                return ([
                    "framework module \(context.resolvedTarget.c99name) {",
                    "    umbrella header \"\(headerPath.basename)\"",
                    "    export *",
                ]
                + generateLinkSection(context: context)
                + ["}"])
                .joined()
            case .umbrellaDirectory(let directoryPath):
                let headers = try walkDirectoryContents(of: directoryPath.scipioAbsolutePath)
                let declarations = headers.map { header in
                    generateHeaderEntry(
                        for: header,
                        of: directoryPath.scipioAbsolutePath,
                        keepPublicHeadersStructure: context.keepPublicHeadersStructure
                    )
                }

                return ([
                    "framework module \(context.resolvedTarget.c99name) {",
                ]
                + Array(declarations).sorted()
                + ["    export *"]
                + generateLinkSection(context: context)
                + ["}"])
                .joined()
            case .none:
                fatalError("Unsupported moduleMapType")
            }
        } else {
            let bridgingHeaderName = "\(context.resolvedTarget.name)-Swift.h"
            return ([
                "framework module \(context.resolvedTarget.c99name) {",
                "    header \"\(bridgingHeaderName)\"",
                "    export *",
                ]
                + generateLinkSection(context: context)
                + ["}"])
                .joined()
        }
    }

    private func walkDirectoryContents(of directoryPath: AbsolutePath) throws -> Set<AbsolutePath> {
        try fileSystem.getDirectoryContents(directoryPath).reduce(into: Set()) { headers, file in
            let path = directoryPath.appending(component: file)
            if fileSystem.isDirectory(path) {
                headers.formUnion(try walkDirectoryContents(of: path))
            } else if file.hasSuffix(".h") {
                headers.insert(path)
            }
        }
    }

    private func generateHeaderEntry(
        for header: AbsolutePath,
        of directoryPath: AbsolutePath,
        keepPublicHeadersStructure: Bool
    ) -> String {
        if keepPublicHeadersStructure {
            let subdirectoryComponents: [String] = if header.dirname.hasPrefix(directoryPath.pathString) {
                header.dirname.dropFirst(directoryPath.pathString.count)
                    .split(separator: "/")
                    .map(String.init)
            } else {
                []
            }

            let path = (subdirectoryComponents + [header.basename]).joined(separator: "/")
            return "    header \"\(path)\""
        } else {
            return "    header \"\(header.basename)\""
        }
    }

    private func generateLinkSection(context: Context) -> [String] {
        context.resolvedTarget.dependencies
            .compactMap(\.module?.c99name)
            .map { "    link framework \"\($0)\"" }
    }

    private func generateModuleMapFile(context: Context, outputPath: AbsolutePath) throws {
        let dirPath = outputPath.parentDirectory
        try fileSystem.createDirectory(dirPath, recursive: true)

        let contents = try generateModuleMapContents(context: context)
        try fileSystem.writeFileContents(outputPath.spmAbsolutePath, string: contents)
    }

    private func constructGeneratedModuleMapPath(context: Context) throws -> AbsolutePath {
        let generatedModuleMapPath = try packageLocator.generatedModuleMapPath(of: context.resolvedTarget, sdk: context.sdk)
        return generatedModuleMapPath
    }

    private func convertCustomModuleMapForFramework(_ customModuleMap: AbsolutePath) throws -> String {
        // Sometimes, targets have their custom modulemaps.
        // However, these are not for frameworks
        // This process converts them to modulemaps for frameworks
        // like `module MyModule` to `framework module MyModule`
        let rawData = try fileSystem.readFileContents(customModuleMap).contents
        guard let contents = String(bytes: rawData, encoding: .utf8) else {
            throw Error.unableToLoadCustomModuleMap(customModuleMap)
        }
        // TODO: Use modern regex
        let regex = try NSRegularExpression(pattern: "^module", options: [])
        let replaced = regex.stringByReplacingMatches(in: contents,
                                                      range: NSRange(location: 0, length: contents.utf16.count),
                                                      withTemplate: "framework module")
        return replaced
    }
}

extension [String] {
    fileprivate func joined() -> String {
        joined(separator: "\n")
            .trimmingCharacters(in: .whitespaces)
    }
}
