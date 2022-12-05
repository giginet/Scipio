import Foundation
import PackageGraph
import PackageModel

struct FrameworkProducer {
    let mode: Runner.Mode
    let rootPackage: Package
    let buildOptions: BuildOptions
    let cacheMode: Runner.Options.CacheMode
    let outputDir: URL
    let fileSystem: any FileSystem

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
        outputDir: URL,
        fileSystem: any FileSystem = localFileSystem
    ) {
        self.mode = mode
        self.rootPackage = rootPackage
        self.buildOptions = buildOptions
        self.cacheMode = cacheMode
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
        let compiler = Compiler(rootPackage: rootPackage, buildOptions: buildOptions)
        let cacheSystem = CacheSystem(rootPackage: rootPackage,
                                      buildOptions: buildOptions,
                                      outputDirectory: outputDir,
                                      storage: cacheStorage)

        guard !libraryTargets.isEmpty else {
            return
        }

        do {
            try await compiler.clean()
        } catch {
            logger.warning("⚠️ Unable to clean project.")
        }

        for product in libraryTargets {
            assert(product.target.type == .library)
            try await buildXCFrameworkIfNeeded(
                product,
                mode: mode,
                outputDir: outputDir,
                cacheSystem: cacheSystem,
                compiler: compiler
            )

            if isCacheEnabled {
                let outputPath = outputDir.appendingPathComponent(product.frameworkName)
                try? await cacheSystem.cacheFramework(at: outputPath, product: product)

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
            } else {
                logger.warning("⚠️ Existing \(frameworkName) is outdated.", metadata: .color(.yellow))
                logger.info("💥 Delete \(frameworkName)", metadata: .color(.red))
                try fileSystem.removeFileTree(at: outputPath)
                let restored = await cacheSystem.restoreCacheIfPossible(product: product)
                needToBuild = !restored
                if restored {
                    logger.info("✅ Restore \(frameworkName) from cache storage", metadata: .color(.green))
                }
            }
        } else {
            needToBuild = true
        }

        if needToBuild {
            try await compiler.createXCFramework(target: product.target,
                                                 outputDirectory: outputDir)
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
        let packages: [ResolvedPackage]
        switch mode {
        case .createPackage:
            packages = rootPackage.graph.rootPackages
        case .prepareDependencies:
            packages = dependenciesPackages(for: rootPackage)
        }
        return packages
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
