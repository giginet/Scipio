import Foundation
import PackageManifestKit
import ScipioKitCore

/// A packager to produce XCFrameworks for system-library targets.
///
/// System-library targets carry a module map and optional headers and have nothing to compile;
/// SwiftPM exposes them to importers through header search paths, which prebuilt-framework
/// consumers do not get. Packaging them as header-only frameworks (headers, a framework module
/// map, and a stub binary XCFramework creation requires) makes `import` of such modules resolve
/// through the framework search consumers already have.
struct SystemLibraryPackager: Compiler {
    enum Error: LocalizedError {
        case unexpectedModuleType(targetName: String)
        case moduleMapNotFound(targetName: String, expectedPath: URL)

        var errorDescription: String? {
            switch self {
            case .unexpectedModuleType(let targetName):
                return """
                System library target \(targetName) was resolved without system-library support. \
                The restored resolved packages cache is stale: please clear it and retry.
                """
            case .moduleMapNotFound(let targetName, let expectedPath):
                return "System library target \(targetName) has no module map at \(expectedPath.path(percentEncoded: false))"
            }
        }
    }

    let descriptionPackage: DescriptionPackage
    private let buildOptions: BuildOptions
    /// Resolves whether a target keeps its public-header directory structure in the produced
    /// framework; the caller owns the per-target override rules.
    private let keepPublicHeadersStructure: @Sendable (_ targetName: String) -> Bool
    private let fileSystem: any FileSystem
    private let executor: any Executor

    init(
        descriptionPackage: DescriptionPackage,
        buildOptions: BuildOptions,
        keepPublicHeadersStructure: @escaping @Sendable (_ targetName: String) -> Bool,
        fileSystem: any FileSystem = LocalFileSystem.default,
        executor: any Executor = ProcessExecutor(errorDecoder: StandardOutputDecoder())
    ) {
        self.descriptionPackage = descriptionPackage
        self.buildOptions = buildOptions
        self.keepPublicHeadersStructure = keepPublicHeadersStructure
        self.fileSystem = fileSystem
        self.executor = executor
    }

    func createXCFramework(buildProduct: BuildProduct, outputDirectory: URL, overwrite: Bool) async throws {
        let target = buildProduct.target

        guard case let .system(includeDir, publicHeaders, moduleMapPath) = target.resolvedModuleType else {
            throw Error.unexpectedModuleType(targetName: target.name)
        }
        guard fileSystem.exists(moduleMapPath) else {
            throw Error.moduleMapNotFound(targetName: target.name, expectedPath: moduleMapPath)
        }
        if target.underlying.pkgConfig != nil {
            logger.warning(
                "⚠️ \(target.name) declares pkgConfig; pkg-config flags are not carried into the prebuilt framework",
                metadata: .color(.yellow)
            )
        }

        let sdks = buildOptions.sdks
        let sdkNames = sdks.map(\.displayName).joined(separator: ", ")
        logger.info("📦 Packaging \(target.name) for \(sdkNames)")

        // System-library headers compile in each importer's context; rewrite against their union.
        let headerIncludeRewriter = CHeaderIncludeRewriter(
            modules: try modulesVisibleToImporters(of: target),
            keepPublicHeadersStructure: { keepPublicHeadersStructure($0.name) }
        )

        for sdk in sdks {
            try await assembleFramework(
                for: target,
                sdk: sdk,
                includeDir: includeDir,
                publicHeaders: publicHeaders,
                headerIncludeRewriter: headerIncludeRewriter
            )
        }

        logger.info("🚀 Combining into XCFramework...")

        let xcFrameworkName = target.xcFrameworkName
        let outputXCFrameworkPath = outputDirectory.appending(component: xcFrameworkName)
        if fileSystem.exists(outputXCFrameworkPath) && overwrite {
            logger.info("💥 Delete \(xcFrameworkName)", metadata: .color(.red))
            try fileSystem.removeFileTree(outputXCFrameworkPath)
        }

        let xcBuildClient = XCBuildClient(
            buildProduct: buildProduct,
            buildOptions: buildOptions,
            configuration: buildOptions.buildConfiguration,
            packageLocator: descriptionPackage
        )
        try await xcBuildClient.createXCFramework(
            sdks: Set(sdks),
            debugSymbols: nil,
            outputPath: outputXCFrameworkPath
        )
    }

    /// Assembles the header-only framework bundle for one SDK.
    private func assembleFramework(
        for target: ResolvedModule,
        sdk: SDK,
        includeDir: URL,
        publicHeaders: [URL],
        headerIncludeRewriter: CHeaderIncludeRewriter
    ) async throws {
        let stubBinaryPath = try await buildStubBinary(for: target, sdk: sdk)
        let infoPlistPath = try generateInfoPlist(for: target, sdk: sdk)
        let frameworkModuleMapGenerator = FrameworkModuleMapGenerator(
            packageLocator: descriptionPackage,
            fileSystem: fileSystem
        )
        let frameworkModuleMapPath = try frameworkModuleMapGenerator.generate(
            resolvedTarget: target,
            sdk: sdk,
            keepPublicHeadersStructure: true
        )

        let frameworkOutputDir = descriptionPackage.assembledFrameworksDirectory(
            buildConfiguration: buildOptions.buildConfiguration,
            sdk: sdk
        )
        let frameworkName = target.name.packageNamed()
        let components = FrameworkComponents(
            isVersionedBundle: false,
            frameworkName: frameworkName,
            frameworkPath: frameworkOutputDir.appending(component: "\(frameworkName).framework"),
            binaryPath: stubBinaryPath,
            infoPlistPath: infoPlistPath,
            swiftModulesPath: nil,
            includeDir: includeDir,
            publicHeaderPaths: Set(publicHeaders),
            bridgingHeaderPath: nil,
            modulemapPath: frameworkModuleMapPath,
            resourceBundlePath: nil
        )

        // The module-map-relative layout must survive regardless of keepPublicHeadersStructure.
        let assembler = FrameworkBundleAssembler(
            frameworkComponents: components,
            keepPublicHeadersStructure: true,
            outputDirectory: frameworkOutputDir,
            fileSystem: fileSystem,
            headerIncludeRewriter: headerIncludeRewriter
        )
        try assembler.assemble()
    }

    /// The dependency closure of every module that transitively depends on this one: exactly
    /// the compile contexts SwiftPM would have compiled these headers in.
    private func modulesVisibleToImporters(of target: ResolvedModule) throws -> [ResolvedModule] {
        // Keyed by name to avoid hashing whole module value trees.
        var visibleModulesByName: [String: ResolvedModule] = [target.name: target]
        for module in descriptionPackage.graph.allModules {
            let closure = try module.recursiveModuleDependencies()
            guard closure.contains(where: { $0.name == target.name }) else { continue }
            visibleModulesByName[module.name] = module
            for dependency in closure {
                visibleModulesByName[dependency.name] = dependency
            }
        }
        return Array(visibleModulesByName.values)
    }

    private func workingDirectory(for target: ResolvedModule, sdk: SDK) -> URL {
        descriptionPackage.workspaceDirectory
            .appending(components: "SystemLibraryFrameworks", target.name, sdk.settingValue)
    }

    /// Builds the stub binary the framework carries. XCFramework creation requires a binary and
    /// reads the slice's platform from it, so the stub is compiled per SDK for its standard
    /// architectures and merged into one static archive.
    private func buildStubBinary(for target: ResolvedModule, sdk: SDK) async throws -> URL {
        let workingDirectory = workingDirectory(for: target, sdk: sdk)
        try fileSystem.createDirectory(workingDirectory, recursive: true)

        // One module-scoped symbol keeps the archive non-empty; an unscoped name would collide
        // when several stub frameworks are linked into the same binary.
        let sourcePath = workingDirectory.appending(component: "stub.c")
        try fileSystem.writeFileContents(
            sourcePath,
            string: "char _scipio_system_library_stub_\(target.c99name) = 0;\n"
        )

        var objectPaths: [URL] = []
        for architecture in sdk.stubBinaryArchitectures {
            let objectPath = workingDirectory.appending(component: "stub_\(architecture).o")
            try await executor.execute(
                [
                    "/usr/bin/xcrun",
                    "--sdk", sdk.stubBinarySDKName,
                    "clang",
                ]
                + sdk.stubBinaryPlatformArguments(architecture: architecture)
                + [
                    "-c", sourcePath.path(percentEncoded: false),
                    "-o", objectPath.path(percentEncoded: false),
                ]
            )
            objectPaths.append(objectPath)
        }

        let binaryPath = workingDirectory.appending(component: target.name.packageNamed())
        try await executor.execute(
            [
                "/usr/bin/xcrun",
                "--sdk", sdk.stubBinarySDKName,
                "libtool",
                "-static",
            ]
            + objectPaths.map { $0.path(percentEncoded: false) }
            + [
                "-o", binaryPath.path(percentEncoded: false),
            ]
        )
        return binaryPath
    }

    /// There is no build step to fill in Info.plist variables, so the file is generated with
    /// concrete values.
    private func generateInfoPlist(for target: ResolvedModule, sdk: SDK) throws -> URL {
        let infoPlistPath = workingDirectory(for: target, sdk: sdk).appending(component: "Info.plist")
        let generator = InfoPlistGenerator(fileSystem: fileSystem)
        try generator.generateForFramework(
            name: target.name.packageNamed(),
            bundleIdentifier: target.name.spm_mangledToBundleIdentifier(),
            at: infoPlistPath
        )
        return infoPlistPath
    }
}

extension SDK {
    /// The standard architectures the stub binary is compiled for. Extra slices are harmless:
    /// consumers pick the library by platform and link only the matching architecture.
    fileprivate var stubBinaryArchitectures: [String] {
        switch self {
        case .macOS, .macCatalyst:
            ["arm64", "x86_64"]
        case .iOS, .tvOS, .visionOS:
            ["arm64"]
        case .iOSSimulator, .tvOSSimulator, .watchOSSimulator, .visionOSSimulator:
            ["arm64", "x86_64"]
        case .watchOS:
            ["arm64", "arm64_32", "armv7k"]
        }
    }

    // Mac Catalyst has no SDK of its own: the stub compiles against the macOS SDK there.
    fileprivate var stubBinarySDKName: String {
        switch self {
        case .macCatalyst:
            SDK.macOS.settingValue
        default:
            settingValue
        }
    }

    // For Mac Catalyst the platform cannot be inferred from the SDK, so the full target
    // triple marks the slice; XCFramework creation reads the platform from the binary.
    fileprivate func stubBinaryPlatformArguments(architecture: String) -> [String] {
        switch self {
        case .macCatalyst:
            ["-target", "\(architecture)-apple-ios-macabi"]
        default:
            ["-arch", architecture]
        }
    }
}
