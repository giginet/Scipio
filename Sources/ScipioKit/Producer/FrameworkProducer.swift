import Foundation
import ScipioStorage
import PackageGraph
import PackageModel
import Collections
import protocol TSCBasic.FileSystem
import var TSCBasic.localFileSystem

struct FrameworkProducer {
    private let descriptionPackage: DescriptionPackage
    private let baseBuildOptions: BuildOptions
    private let buildOptionsMatrix: [String: BuildOptions]
    private let cacheMode: Runner.Options.CacheMode
    private let overwrite: Bool
    private let outputDir: URL
    private let fileSystem: any FileSystem
    private let toolchainEnvironment: [String: String]?

    private func cacheStorages(for actor: Runner.Options.CacheMode.CacheActorKind) -> [any CacheStorage]? {
        switch cacheMode {
        case .disabled, .project:
            return nil
        case .storage(let storage, let actors):
            return actors.contains(actor) ? [storage] : nil
        case .storages(let storages):
            return storages.compactMap { $0.actors.contains(actor) ? $0.storage : nil }
        }
    }

    private var isProducingCacheEnabled: Bool {
        switch cacheMode {
        case .disabled:
            return false
        case .project:
            return true
        case .storage(_, let actors):
            return actors.contains(.producer)
        case .storages(let storages):
            return storages.contains { $0.actors.contains(.producer) }
        }
    }

    private var shouldGenerateVersionFile: Bool {
        // cacheMode is not disabled
        if case .disabled = cacheMode {
            return false
        }

        // Enable only in prepare mode
        if case .prepareDependencies = descriptionPackage.mode {
            return true
        }
        return false
    }

    init(
        descriptionPackage: DescriptionPackage,
        buildOptions: BuildOptions,
        buildOptionsMatrix: [String: BuildOptions],
        cacheMode: Runner.Options.CacheMode,
        overwrite: Bool,
        outputDir: URL,
        toolchainEnvironment: [String: String]? = nil,
        fileSystem: any FileSystem = localFileSystem
    ) {
        self.descriptionPackage = descriptionPackage
        self.baseBuildOptions = buildOptions
        self.buildOptionsMatrix = buildOptionsMatrix
        self.cacheMode = cacheMode
        self.overwrite = overwrite
        self.outputDir = outputDir
        self.toolchainEnvironment = toolchainEnvironment
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

        if fileSystem.exists(descriptionPackage.assembledFrameworksRootDirectory) {
            try fileSystem.removeFileTree(descriptionPackage.assembledFrameworksRootDirectory)
        }
    }

    private func processAllTargets(buildProducts: [BuildProduct]) async throws {
        guard !buildProducts.isEmpty else {
            return
        }

        let allTargets = OrderedSet(buildProducts.compactMap { buildProduct -> CacheSystem.CacheTarget? in
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
        let pinsStore = try descriptionPackage.workspace.pinsStore.load()

        let cacheSystem = CacheSystem(
            pinsStore: pinsStore,
            outputDirectory: outputDir,
            writableStorages: cacheStorages(for: .producer) ?? []
        )
        let cacheEnabledTargets: Set<CacheSystem.CacheTarget>
        if cacheMode.isConsumingCacheEnabled {
            cacheEnabledTargets = await restoreAllAvailableCaches(
                availableTargets: Set(allTargets),
                cacheSystem: cacheSystem,
                readableStorages: cacheStorages(for: .consumer)
            )
        } else {
            cacheEnabledTargets = []
        }

        let targetsToBuild = allTargets.subtracting(cacheEnabledTargets)

        for target in targetsToBuild {
            try await buildXCFrameworks(
                target,
                outputDir: outputDir,
                buildOptionsMatrix: buildOptionsMatrix
            )
        }

        if isProducingCacheEnabled {
            await cacheSystem.cacheFrameworks(Set(targetsToBuild))
        }

        if shouldGenerateVersionFile {
            // Versionfiles should be generate for all targets
            for target in allTargets {
                await generateVersionFile(for: target, using: cacheSystem)
            }
        }
    }

    private func restoreAllAvailableCaches(
        availableTargets: Set<CacheSystem.CacheTarget>,
        cacheSystem: CacheSystem,
        readableStorages: [any CacheStorage]?
    ) async -> Set<CacheSystem.CacheTarget> {
        guard let readableStorages, !readableStorages.isEmpty else {
            // This is for `CacheMode.project`.
            //
            // In that case just checking whether the valid caches (already built frameworks under the project)
            // exist or not (not restoring anything from external locations).
            return await restoreCachesForTargets(
                availableTargets,
                cacheSystem: cacheSystem,
                cacheStorage: nil
            )
        }

        var remainingTargets = availableTargets
        var restored: Set<CacheSystem.CacheTarget> = []

        for index in readableStorages.indices {
            let storage = readableStorages[index]

            if index != readableStorages.startIndex {
                logger.info("Falling back to \(storage)", metadata: .color(.green))
            }

            let restoredPerStorage = await restoreCachesForTargets(
                remainingTargets,
                cacheSystem: cacheSystem,
                cacheStorage: storage
            )
            restored.formUnion(restoredPerStorage)

            remainingTargets.subtract(restoredPerStorage)
            if remainingTargets.isEmpty {
                break
            }
        }

        return restored
    }

    private func restoreCachesForTargets(
        _ targets: Set<CacheSystem.CacheTarget>,
        cacheSystem: CacheSystem,
        cacheStorage: (any CacheStorage)?
    ) async -> Set<CacheSystem.CacheTarget> {
        let chunked = targets.chunks(ofCount: cacheStorage?.parallelNumber ?? CacheSystem.defaultParalellNumber)

        var restored: Set<CacheSystem.CacheTarget> = []
        for chunk in chunked {
            let restorer = Restorer(outputDir: outputDir, fileSystem: fileSystem)
            await withTaskGroup(of: CacheSystem.CacheTarget?.self) { group in
                for target in chunk {
                    group.addTask {
                        do {
                            let restored = try await restorer.restore(
                                target: target,
                                cacheSystem: cacheSystem,
                                cacheStorage: cacheStorage
                            )
                            return restored ? target : nil
                        } catch {
                            return nil
                        }
                    }
                }
                for await target in group.compactMap({ $0 }) {
                    restored.insert(target)
                }
            }
        }
        return restored
    }

    /// Sendable interface to provide restore caches
    private struct Restorer: Sendable {
        let outputDir: URL
        let fileSystem: any FileSystem

        // Return true if pre-built artifact is available (already existing or restored from cache)
        func restore(
            target: CacheSystem.CacheTarget,
            cacheSystem: CacheSystem,
            cacheStorage: (any CacheStorage)?
        ) async throws -> Bool {
            let product = target.buildProduct
            let frameworkName = product.frameworkName
            let outputPath = outputDir.appendingPathComponent(product.frameworkName)
            let exists = fileSystem.exists(outputPath.absolutePath)

            let expectedCacheKey = try await cacheSystem.calculateCacheKey(of: target)
            let isValidCache = await cacheSystem.existsValidCache(cacheKey: expectedCacheKey)
            let expectedCacheKeyHash = try expectedCacheKey.calculateChecksum()

            if isValidCache && exists {
                logger.info(
                    "✅ Valid \(product.target.name).xcframework (\(expectedCacheKeyHash)) is exists. Skip building.", metadata: .color(.green)
                )
                return true
            } else {
                if exists {
                    logger.warning("⚠️ Existing \(frameworkName) is outdated.", metadata: .color(.yellow))
                    logger.info("🗑️ Delete \(frameworkName)", metadata: .color(.red))
                    try fileSystem.removeFileTree(outputPath.absolutePath)
                }

                guard let cacheStorage else {
                    return false
                }

                let restoreResult = await cacheSystem.restoreCacheIfPossible(target: target, storage: cacheStorage)
                switch restoreResult {
                case .succeeded:
                    logger.info("✅ Restore \(frameworkName) (\(expectedCacheKeyHash)) from cache storage.", metadata: .color(.green))
                    return true
                case .failed(let error):
                    logger.warning("⚠️ Restoring \(frameworkName) (\(expectedCacheKeyHash)) is failed", metadata: .color(.yellow))
                    if let description = error?.errorDescription {
                        logger.warning("\(description)", metadata: .color(.yellow))
                    }
                    return false
                case .noCache:
                    return false
                }
            }
        }
    }

    @discardableResult
    private func buildXCFrameworks(
        _ target: CacheSystem.CacheTarget,
        outputDir: URL,
        buildOptionsMatrix: [String: BuildOptions]
    ) async throws -> Set<CacheSystem.CacheTarget> {
        let product = target.buildProduct
        let buildOptions = target.buildOptions

        switch product.target.type {
        case .library:
            let compiler = PIFCompiler(
                descriptionPackage: descriptionPackage,
                buildOptions: buildOptions,
                buildOptionsMatrix: buildOptionsMatrix
            )
            try await compiler.createXCFramework(buildProduct: product,
                                                 outputDirectory: outputDir,
                                                 overwrite: overwrite)
        case .binary:
            guard let binaryTarget = product.target.underlying as? BinaryModule else {
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

    private func generateVersionFile(for target: CacheSystem.CacheTarget, using cacheSystem: CacheSystem) async {
        do {
            try await cacheSystem.generateVersionFile(for: target)
        } catch {
            logger.warning("⚠️ Could not create VersionFile. This framework will not be cached.", metadata: .color(.yellow))
        }
    }
}

extension Runner.Options.CacheMode {
    fileprivate var isConsumingCacheEnabled: Bool {
        switch self {
        case .disabled:
            return false
        case .project:
            return true
        case .storage(_, let actors):
            return actors.contains(.consumer)
        case .storages(let storages):
            return storages.contains { $0.actors.contains(.consumer) }
        }
    }
}
