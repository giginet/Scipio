import Foundation
import TSCBasic
import AsyncOperations

// A generator to generate modulemaps which are distributed in the XCFramework
struct FrameworkModuleMapGenerator {
    private struct Context {
        var resolvedTarget: ResolvedModule
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
        resolvedTarget: ResolvedModule,
        sdk: SDK,
        keepPublicHeadersStructure: Bool
    ) async throws -> AbsolutePath? {
        let context = Context(
            resolvedTarget: resolvedTarget,
            sdk: sdk,
            keepPublicHeadersStructure: keepPublicHeadersStructure
        )

        if case let .clang(includeDir, _) = resolvedTarget.resolvedModuleType {
            let moduleMapGenerator = ModuleMapGenerator(
                targetName: resolvedTarget.name,
                moduleName: resolvedTarget.c99name,
                publicHeadersDir: includeDir,
                fileSystem: fileSystem
            )
            let moduleMapType = await moduleMapGenerator.determineModuleMapType()

            switch moduleMapType {
            case .custom, .umbrellaHeader, .umbrellaDirectory:
                let path = try constructGeneratedModuleMapPath(context: context)
                try await generateModuleMapFile(context: context, moduleMapType: moduleMapType, outputPath: path)
                return path
            case .none:
                return nil
            }
        } else {
            let path = try constructGeneratedModuleMapPath(context: context)
            try await generateModuleMapFile(context: context, moduleMapType: nil, outputPath: path)
            return path
        }
    }

    private func generateModuleMapContents(context: Context, moduleMapType: ModuleMapType?) async throws -> String {
        if let moduleMapType {
            switch moduleMapType {
            case .custom(let customModuleMap):
                return try await convertCustomModuleMapForFramework(customModuleMap.absolutePath)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            case .umbrellaHeader(let headerPath):
                return ([
                    "framework module \(context.resolvedTarget.c99name) {",
                    "    umbrella header \"\(headerPath.absolutePath.basename)\"",
                    "    export *",
                ]
                + generateLinkSection(context: context)
                + ["}"])
                .joined()
            case .umbrellaDirectory(let directoryPath):
                let headers = try await walkDirectoryContents(of: directoryPath.absolutePath)
                let declarations = headers.map { header in
                    generateHeaderEntry(
                        for: header,
                        of: directoryPath.absolutePath,
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

    private func walkDirectoryContents(of directoryPath: AbsolutePath) async throws -> Set<AbsolutePath> {
        try await fileSystem.getDirectoryContents(directoryPath.asURL).asyncReduce(into: Set()) { headers, file in
            let path = directoryPath.appending(component: file)
            if await fileSystem.isDirectory(path.asURL) {
                headers.formUnion(try await walkDirectoryContents(of: path))
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

    private func generateModuleMapFile(
        context: Context,
        moduleMapType: ModuleMapType?,
        outputPath: AbsolutePath
    ) async throws {
        let dirPath = outputPath.parentDirectory
        try await fileSystem.createDirectory(dirPath.asURL, recursive: true)

        let contents = try await generateModuleMapContents(context: context, moduleMapType: moduleMapType)
        try await fileSystem.writeFileContents(outputPath.asURL, string: contents)
    }

    private func constructGeneratedModuleMapPath(context: Context) throws -> AbsolutePath {
        let generatedModuleMapPath = try packageLocator.generatedModuleMapPath(of: context.resolvedTarget, sdk: context.sdk)
        return generatedModuleMapPath
    }

    private func convertCustomModuleMapForFramework(_ customModuleMap: AbsolutePath) async throws -> String {
        // Sometimes, targets have their custom modulemaps.
        // However, these are not for frameworks
        // This process converts them to modulemaps for frameworks
        // like `module MyModule` to `framework module MyModule`
        let rawData = try await fileSystem.readFileContents(customModuleMap.asURL)
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
