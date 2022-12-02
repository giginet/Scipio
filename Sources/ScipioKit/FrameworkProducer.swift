import Foundation
import PackageGraph

struct BuildProduct {
    var package: ResolvedPackage
    var target: ResolvedTarget

    func frameworkName() -> String {
        "\(target.name.packageNamed()).xcframework"
    }
}

struct FrameworkProducer {
    let rootPackage: Package
    let buildOptions: BuildOptions
    let cacheMode: Runner.Options.CacheMode
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
        rootPackage: Package,
        buildOptions: BuildOptions,
        cacheMode: Runner.Options.CacheMode,
        fileSystem: any FileSystem = localFileSystem
    ) {
        self.rootPackage = rootPackage
        self.buildOptions = buildOptions
        self.cacheMode = cacheMode
        self.fileSystem = fileSystem
    }

    func produce(mode: Runner.Mode, outputDir: URL) async throws {
        let cacheSystem = CacheSystem(rootPackage: rootPackage,
                                      buildOptions: buildOptions,
                                      outputDirectory: outputDir,
                                      storage: cacheStorage)
        let compiler = Compiler(rootPackage: rootPackage, buildOptions: buildOptions)
        try await compiler.clean()

        let products = productsToBuild(for: mode)

        for product in products {
            let frameworkName = product.frameworkName()
            let xcframeworkPath = outputDir.appendingPathComponent(frameworkName)
            let exists = fileSystem.exists(xcframeworkPath)

            if exists && isCacheEnabled {
                let isValidCache = await cacheSystem.existsValidCache(product: product)
                if isValidCache {
                    logger.info("✅ Valid \(product.target.name).xcframework is exists. Skip building.", metadata: .color(.green))
                    continue
                } else {
                    logger.warning("⚠️ Existing \(frameworkName) is outdated.", metadata: .color(.yellow))
                    logger.info("💥 Delete \(frameworkName)", metadata: .color(.red))
                    try fileSystem.removeFileTree(at: xcframeworkPath)
                }
            }

            let frameworkPath = outputDir.appendingPathComponent(frameworkName)
            let restored = await cacheSystem.restoreCacheIfPossible(product: product)
            if restored {
                logger.info("✅ Restore \(frameworkName) from cache storage", metadata: .color(.green))
            } else {
                try await compiler.createXCFramework(target: product.target,
                                                     outputDirectory: outputDir)
            }

            try? await cacheSystem.cacheFramework(at: frameworkPath, product: product)

            if case .prepareDependencies = mode {
                try await generateVersionFile(for: product, using: cacheSystem)
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

    private func productsToBuild(for mode: Runner.Mode) -> [BuildProduct] {
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
                    .filter { $0.type == .library }
                    .map { BuildProduct(package: package, target: $0) }
            }
    }

    private func dependenciesPackages(for package: Package) -> [ResolvedPackage] {
        package.graph.packages
            .filter { $0.manifest.displayName != package.manifest.displayName }
    }
}
