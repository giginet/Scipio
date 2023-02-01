import Foundation
import PackageGraph
import PackageModel
import OrderedCollections
import TSCBasic

struct FrameworkProducer {
    private let mode: Runner.Mode
    private let rootPackage: Package
    private let buildOptions: BuildOptions
    private let cacheMode: Runner.Options.CacheMode
    private let platformMatrix: PlatformMatrix
    private let overwrite: Bool
    private let outputDir: URL
    private let fileSystem: any FileSystem

    private var cacheStorage: (any CacheStorage)? {
        switch cacheMode {
        case .disabled, .project: return nil
        case .storage(let storage): return storage
        }
    }

    private var isCacheEnabled: Bool {
        switch cacheMode {
        case .disabled: return false
        case .project, .storage: return true
        }
    }

    init(
        mode: Runner.Mode,
        rootPackage: Package,
        buildOptions: BuildOptions,
        cacheMode: Runner.Options.CacheMode,
        platformMatrix: PlatformMatrix,
        overwrite: Bool,
        outputDir: URL,
        fileSystem: any FileSystem = localFileSystem
    ) {
        self.mode = mode
        self.rootPackage = rootPackage
        self.buildOptions = buildOptions
        self.cacheMode = cacheMode
        self.platformMatrix = platformMatrix
        self.overwrite = overwrite
        self.outputDir = outputDir
        self.fileSystem = fileSystem
    }

    func produce() async throws {
        try await clean()

        let targets = try allTargets(for: mode)
        try await processAllTargets(
            targets: targets.filter { [.library, .binary].contains($0.target.type) }
        )
    }

    func clean() async throws {
        if fileSystem.exists(rootPackage.derivedDataPath.absolutePath) {
            try fileSystem.removeFileTree(rootPackage.derivedDataPath.absolutePath)
        }
    }

    private func processAllTargets(targets: [BuildProduct]) async throws {
        guard !targets.isEmpty else {
            return
        }

        for product in targets {
            assert([.library, .binary].contains(product.target.type))
            let buildOptionsForProduct = buildOptions.overridingSDKs(for: product, platformMatrix: platformMatrix)

            let cacheSystem = CacheSystem(rootPackage: rootPackage,
                                          buildOptions: buildOptionsForProduct,
                                          outputDirectory: outputDir,
                                          storage: cacheStorage)

            try await prepareXCFrameworkIfNeeded(
                product,
                mode: mode,
                buildOptions: buildOptionsForProduct,
                outputDir: outputDir,
                cacheSystem: cacheSystem
            )

            if isCacheEnabled {
                let outputPath = outputDir.appendingPathComponent(product.frameworkName)
                try? await cacheSystem.cacheFramework(product, at: outputPath)

                if case .prepareDependencies = mode {
                    try await generateVersionFile(for: product, using: cacheSystem)
                }
            }
        }
    }

    private func prepareXCFrameworkIfNeeded(
        _ product: BuildProduct,
        mode: Runner.Mode,
        buildOptions: BuildOptions,
        outputDir: URL,
        cacheSystem: CacheSystem
    ) async throws {
        let frameworkName = product.frameworkName
        let outputPath = outputDir.appendingPathComponent(product.frameworkName)
        let exists = fileSystem.exists(outputPath.absolutePath)

        let needToBuild: Bool
        if exists, isCacheEnabled {
            let isValidCache = await cacheSystem.existsValidCache(product: product)
            if isValidCache {
                logger.info("✅ Valid \(product.target.name).xcframework is exists. Skip building.", metadata: .color(.green))
                return
            }
            logger.warning("⚠️ Existing \(frameworkName) is outdated.", metadata: .color(.yellow))
            logger.info("🗑️ Delete \(frameworkName)", metadata: .color(.red))
            try fileSystem.removeFileTree(outputPath.absolutePath)
            let restored = await cacheSystem.restoreCacheIfPossible(product: product)
            needToBuild = !restored
            if restored {
                logger.info("✅ Restore \(frameworkName) from cache storage", metadata: .color(.green))
            }
        } else {
            needToBuild = true
        }

        if needToBuild {
            switch product.target.type {
            case .library:
                let compiler = PIFCompiler(rootPackage: rootPackage, buildOptions: buildOptions)
                try await compiler.createXCFramework(buildProduct: product,
                                                     outputDirectory: outputDir,
                                                     overwrite: overwrite)
            case .binary:
                guard let binaryTarget = product.target.underlyingTarget as? BinaryTarget else {
                    fatalError("Unexpected failure")
                }
                let binaryExtractor = BinaryExtractor(
                    package: rootPackage,
                    outputDirectory: outputDir,
                    fileSystem: fileSystem
                )
                try binaryExtractor.extract(of: binaryTarget, overwrite: overwrite)
                logger.info("✅ Copy \(binaryTarget.c99name).xcframework", metadata: .color(.green))
            default:
                fatalError("Unexpected target type \(product.target.type)")
            }
        }
    }

    private func generateVersionFile(for product: BuildProduct, using cacheSystem: CacheSystem) async throws {
        do {
            try await cacheSystem.generateVersionFile(for: product)
        } catch {
            logger.warning("⚠️ Could not create VersionFile. This framework will not be cached.", metadata: .color(.yellow))
        }
    }

    private func allTargets(for mode: Runner.Mode) throws -> [BuildProduct] {
        switch  mode {
        case .createPackage:
            return rootPackage.graph.rootPackages
                .flatMap { package in
                    package.targets
                        .map { BuildProduct(package: package, target: $0) }
                }
        case .prepareDependencies:
            guard let descriptionTarget = rootPackage.graph.rootPackages.first?.targets.first else {
                return []
            }
            return try descriptionTarget.recursiveDependencies().compactMap { dependency -> BuildProduct? in
                guard let target = dependency.target else {
                    return nil
                }
                guard let package = rootPackage.graph.package(for: target) else {
                    return nil
                }
                return BuildProduct(package: package, target: target)
            }
        }
    }

    private func dependenciesPackages(for package: Package) -> [ResolvedPackage] {
        package.graph.packages
            .filter { $0.manifest.displayName != package.manifest.displayName }
    }
}

extension BuildOptions {
    fileprivate func overridingSDKs(for product: BuildProduct, platformMatrix: PlatformMatrix) -> BuildOptions {
        guard let overriddenSDKs = platformMatrix[product.target.name] else {
            return self
        }
        var newBuildOptions = self
        newBuildOptions.sdks = overriddenSDKs
        return newBuildOptions
    }
}
