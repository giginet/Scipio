import Foundation
import PackageGraph
import PackageModel
import OrderedCollections

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
        let targets = allTargets(for: mode)
        try await buildAllLibraryTargets(
            libraryTargets: targets.filter { $0.target.type == .library }
        )

        let binaryTargets = targets.compactMap(\.binaryTarget)
        try await extractAllBinaryTarget(binaryTargets: binaryTargets)
    }

    private func buildAllLibraryTargets(libraryTargets: [BuildProduct]) async throws {
        guard !libraryTargets.isEmpty else {
            return
        }

        let cleaner = Cleaner(rootPackage: rootPackage)
        do {
            try await cleaner.clean()
        } catch {
            logger.warning("⚠️ Unable to clean project.")
        }

        for product in libraryTargets {
            assert(product.target.type == .library)

            let buildOptionsForProduct = buildOptions.overridingSDKs(for: product, platformMatrix: platformMatrix)
            let compiler = Compiler(rootPackage: rootPackage, buildOptions: buildOptionsForProduct)

            let cacheSystem = CacheSystem(rootPackage: rootPackage,
                                          buildOptions: buildOptionsForProduct,
                                          outputDirectory: outputDir,
                                          storage: cacheStorage)

            try await buildXCFrameworkIfNeeded(
                product,
                mode: mode,
                outputDir: outputDir,
                cacheSystem: cacheSystem,
                compiler: compiler
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

    private func buildXCFrameworkIfNeeded(
        _ product: BuildProduct,
        mode: Runner.Mode,
        outputDir: URL,
        cacheSystem: CacheSystem,
        compiler: Compiler<some Executor>
    ) async throws {
        let frameworkName = product.frameworkName
        let outputPath = outputDir.appendingPathComponent(product.frameworkName)
        let exists = fileSystem.exists(outputPath)

        let needToBuild: Bool
        if exists, isCacheEnabled {
            let isValidCache = await cacheSystem.existsValidCache(product: product)
            if isValidCache {
                logger.info("✅ Valid \(product.target.name).xcframework is exists. Skip building.", metadata: .color(.green))
                return
            }
            logger.warning("⚠️ Existing \(frameworkName) is outdated.", metadata: .color(.yellow))
            logger.info("💥 Delete \(frameworkName)", metadata: .color(.red))
            try fileSystem.removeFileTree(at: outputPath)
            let restored = await cacheSystem.restoreCacheIfPossible(product: product)
            needToBuild = !restored
            if restored {
                logger.info("✅ Restore \(frameworkName) from cache storage", metadata: .color(.green))
            }
        } else {
            needToBuild = true
        }

        if needToBuild {
            try await compiler.createXCFramework(target: product.target,
                                                 outputDirectory: outputDir,
                                                 overwrite: overwrite)
        }
    }

    private func extractAllBinaryTarget(binaryTargets: [BinaryTarget]) async throws {
        for binaryTarget in binaryTargets {
            let binaryExtractor = BinaryExtractor(
                package: rootPackage,
                outputDirectory: outputDir,
                fileSystem: fileSystem
            )
            try binaryExtractor.extract(of: binaryTarget)
            logger.info("✅ Copy \(binaryTarget.c99name).xcframework", metadata: .color(.green))
        }
    }

    private func generateVersionFile(for product: BuildProduct, using cacheSystem: CacheSystem) async throws {
        do {
            try await cacheSystem.generateVersionFile(for: product)
        } catch {
            logger.warning("⚠️ Could not create VersionFile. This framework will not be cached.", metadata: .color(.yellow))
        }
    }

    private func allTargets(for mode: Runner.Mode) -> [BuildProduct] {
        rootPackage.resolveDependenciesPackages(for: mode)
            .flatMap { package in
                package.targets
                    .map { BuildProduct(package: package, target: $0) }
            }
    }

    private func dependenciesPackages(for package: Package) -> [ResolvedPackage] {
        package.graph.packages
            .filter { $0.manifest.displayName != package.manifest.displayName }
    }
}

extension Package {
    fileprivate func resolveDependenciesPackages(for mode: Runner.Mode) -> [ResolvedPackage] {
        switch  mode {
        case .createPackage:
            return graph.rootPackages
        case .prepareDependencies:
            return graph.packages
             .filter { $0.manifest.displayName != manifest.displayName }
        }
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
