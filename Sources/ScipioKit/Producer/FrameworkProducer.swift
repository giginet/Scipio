import Foundation
import PackageGraph
import PackageModel
import OrderedCollections
import TSCBasic

struct FrameworkProducer {
    private let descriptionPackage: DescriptionPackage
    private let baseBuildOptions: BuildOptions
    private let buildOptionsMatrix: [String: BuildOptions]
    private let cacheMode: Runner.Options.CacheMode
    private let overwrite: Bool
    private let outputDir: URL
    private let fileSystem: any FileSystem

    private var cacheStorage: (any CacheStorage)? {
        switch cacheMode {
        case .disabled, .project: return nil
        case .storage(let storage, _): return storage
        }
    }

    private var isConsumingCacheEnabled: Bool {
        switch cacheMode {
        case .disabled: return false
        case .project: return true
        case .storage(_, let actors):
            return actors.contains(.consumer)
        }
    }

    private var isProducingCacheEnabled: Bool {
        switch cacheMode {
        case .disabled: return false
        case .project: return true
        case .storage(_, let actors):
            return actors.contains(.producer)
        }
    }

    init(
        descriptionPackage: DescriptionPackage,
        buildOptions: BuildOptions,
        buildOptionsMatrix: [String: BuildOptions],
        cacheMode: Runner.Options.CacheMode,
        overwrite: Bool,
        outputDir: URL,
        fileSystem: any FileSystem = localFileSystem
    ) {
        self.descriptionPackage = descriptionPackage
        self.baseBuildOptions = buildOptions
        self.buildOptionsMatrix = buildOptionsMatrix
        self.cacheMode = cacheMode
        self.overwrite = overwrite
        self.outputDir = outputDir
        self.fileSystem = fileSystem
    }

    func produce() async throws {
        try await clean()

        let targets = try descriptionPackage.resolveBuildProducts()
        try await processAllTargets(
            buildProducts: targets.filter { [.library, .binary].contains($0.target.type) }
        )
    }

    private func overriddenBuildOption(for buildProduct: BuildProduct) -> BuildOptions {
        buildOptionsMatrix[buildProduct.target.name] ?? baseBuildOptions
    }

    func clean() async throws {
        if fileSystem.exists(descriptionPackage.derivedDataPath) {
            try fileSystem.removeFileTree(descriptionPackage.derivedDataPath)
        }
    }

    private func processAllTargets(buildProducts: [BuildProduct]) async throws {
        guard !buildProducts.isEmpty else {
            return
        }

        let allTargets = Set(buildProducts.compactMap { buildProduct -> CacheSystem.CacheTarget? in
            guard [.library, .binary].contains(buildProduct.target.type) else {
                assertionFailure("Invalid target type")
                return nil
            }
            let buildOptionsForProduct = overriddenBuildOption(for: buildProduct)
            return CacheSystem.CacheTarget(
                buildProduct: buildProduct,
                buildOptions: buildOptionsForProduct
            )
        })
        let cacheSystem = CacheSystem(descriptionPackage: descriptionPackage,
                                      outputDirectory: outputDir,
                                      storage: cacheStorage)
        let cacheEnabledTargets: Set<CacheSystem.CacheTarget>
        if isConsumingCacheEnabled {
            cacheEnabledTargets = try await downloadAllAvailableCaches(targets: allTargets)
        } else {
            cacheEnabledTargets = []
        }

        let targetsToBuild = allTargets.subtracting(cacheEnabledTargets)

        for target in targetsToBuild {
            try await buildXCFrameworks(
                target,
                outputDir: outputDir,
                cacheSystem: cacheSystem
            )
        }

        if isProducingCacheEnabled {
            try await produceCaches(targets: targetsToBuild, cacheSystem: cacheSystem)
        }
    }

    private func downloadAllAvailableCaches(targets: Set<CacheSystem.CacheTarget>) async throws -> Set<CacheSystem.CacheTarget>  {
//        if exists, isConsumingCacheEnabled {
//            let isValidCache = await cacheSystem.existsValidCache(product: product)
//            if isValidCache {
//                logger.info("✅ Valid \(product.target.name).xcframework is exists. Skip building.", metadata: .color(.green))
//                return
//            }
//            logger.warning("⚠️ Existing \(frameworkName) is outdated.", metadata: .color(.yellow))
//            logger.info("🗑️ Delete \(frameworkName)", metadata: .color(.red))
//            try fileSystem.removeFileTree(outputPath.absolutePath)
//            let restored = await cacheSystem.restoreCacheIfPossible(product: product)
//            needToBuild = !restored
//            if restored {
//                logger.info("✅ Restore \(frameworkName) from cache storage", metadata: .color(.green))
//            }
//        } else {
//            needToBuild = true
//        }
        return []
    }

    @discardableResult
    private func buildXCFrameworks(
        _ target: CacheSystem.CacheTarget,
        outputDir: URL,
        cacheSystem: CacheSystem
    ) async throws -> Set<CacheSystem.CacheTarget> {
        let product = target.buildProduct
        let buildOptions = target.buildOptions

        let frameworkName = product.frameworkName
        let outputPath = outputDir.appendingPathComponent(product.frameworkName)
        let exists = fileSystem.exists(outputPath.absolutePath)

        switch product.target.type {
        case .library:
            let compiler = PIFCompiler(descriptionPackage: descriptionPackage, buildOptions: buildOptions)
            try await compiler.createXCFramework(buildProduct: product,
                                                 outputDirectory: outputDir,
                                                 overwrite: overwrite)
        case .binary:
            guard let binaryTarget = product.target.underlyingTarget as? BinaryTarget else {
                fatalError("Unexpected failure")
            }
            let binaryExtractor = BinaryExtractor(
                package: descriptionPackage,
                outputDirectory: outputDir,
                fileSystem: fileSystem
            )
            try binaryExtractor.extract(of: binaryTarget, overwrite: overwrite)
            logger.info("✅ Copy \(binaryTarget.c99name).xcframework", metadata: .color(.green))
        default:
            fatalError("Unexpected target type \(product.target.type)")
        }

        return []
    }

    private func produceCaches(targets: Set<CacheSystem.CacheTarget>, cacheSystem: CacheSystem) async throws {
    }

//    private func generateVersionFile(for target: CacheSystem.CacheTarget, using cacheSystem: CacheSystem) async throws {
//        do {
//            try await cacheSystem.generateVersionFile(for: target)
//        } catch {
//            logger.warning("⚠️ Could not create VersionFile. This framework will not be cached.", metadata: .color(.yellow))
//        }
//    }
}
