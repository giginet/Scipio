import Foundation
import ScipioStorage
import Collections
import PackageManifestKit

struct FrameworkProducer {
    private let descriptionPackage: DescriptionPackage
    private let baseBuildOptions: BuildOptions
    private let buildOptionsMatrix: [String: BuildOptions]
    private let cachePolicies: [Runner.Options.CachePolicy]
    private let overwrite: Bool
    private let outputDir: URL
    private let fileSystem: any FileSystem

    private var shouldGenerateVersionFile: Bool {
        // cache is not disabled
        guard !cachePolicies.isEmpty else {
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
        cachePolicies: [Runner.Options.CachePolicy],
        overwrite: Bool,
        outputDir: URL,
        fileSystem: any FileSystem = LocalFileSystem.default
    ) {
        self.descriptionPackage = descriptionPackage
        self.baseBuildOptions = buildOptions
        self.buildOptionsMatrix = buildOptionsMatrix
        self.cachePolicies = cachePolicies
        self.overwrite = overwrite
        self.outputDir = outputDir
        self.fileSystem = fileSystem
    }

    func produce() async throws {
        try await clean()

        let buildProductDependencyGraph = try descriptionPackage.resolveBuildProductDependencyGraph()

        try await processAllTargets(buildProductDependencyGraph: buildProductDependencyGraph)
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

    private func processAllTargets(buildProductDependencyGraph: DependencyGraph<BuildProduct>) async throws {
        guard !buildProductDependencyGraph.rootNodes.isEmpty else {
            return
        }

        var targetGraph = buildProductDependencyGraph.map { buildProduct in
            let buildOptionsForProduct = overriddenBuildOption(for: buildProduct)
            return CacheSystem.CacheTarget(
                buildProduct: buildProduct,
                buildOptions: buildOptionsForProduct
            )
        }

        let allTargets = targetGraph.allNodes.map(\.value)

        let cacheSystem = CacheSystem(outputDirectory: outputDir)

        let dependencyGraphToBuild: DependencyGraph<CacheSystem.CacheTarget>
        if cachePolicies.isEmpty {
            // no-op because cache is disabled
            dependencyGraphToBuild = targetGraph
        } else {
            let targets = Set(targetGraph.allNodes.map(\.value))

            // Validate the existing frameworks in `outputDir` before restoration
            let valid = await validateExistingFrameworks(
                availableTargets: targets,
                cacheSystem: cacheSystem
            )

            let storagesWithConsumer = cachePolicies.storages(for: .consumer)
            if storagesWithConsumer.isEmpty {
                // no-op
                targetGraph.remove(valid)
            } else {
                let restored = await restoreAllAvailableCachesIfNeeded(
                    availableTargets: targets.subtracting(valid),
                    to: storagesWithConsumer,
                    cacheSystem: cacheSystem
                )

                if !restored.isEmpty {
                    await shareRestoredCachesToProducers(restored, cacheSystem: cacheSystem)
                }

                let skipTargets = valid.union(restored)
                targetGraph.remove(skipTargets)
            }
            dependencyGraphToBuild = targetGraph
        }

        let targetBuildResult = await buildTargets(dependencyGraphToBuild)

        let builtTargets: OrderedCollections.OrderedSet<CacheSystem.CacheTarget> = switch targetBuildResult {
            case .completed(let builtTargets),
                 .interrupted(let builtTargets, _):
                builtTargets
            }

        await cacheFrameworksIfNeeded(Set(builtTargets), cacheSystem: cacheSystem)

        if shouldGenerateVersionFile {
            // Versionfiles should be generate for all targets
            for target in allTargets {
                await generateVersionFile(for: target, using: cacheSystem)
            }
        }

        if case .interrupted(_, let error) = targetBuildResult {
            throw error
        }
    }

    private func validateExistingFrameworks(
        availableTargets: Set<CacheSystem.CacheTarget>,
        cacheSystem: CacheSystem
    ) async -> Set<CacheSystem.CacheTarget> {
        let chunked = availableTargets.chunks(ofCount: CacheSystem.defaultParalellNumber)

        var validFrameworks: Set<CacheSystem.CacheTarget> = []
        for chunk in chunked {
            await withTaskGroup(of: CacheSystem.CacheTarget?.self) { group in
                for target in chunk {
                    group.addTask { [outputDir, fileSystem] in
                        do {
                            let product = target.buildProduct
                            let frameworkName = product.frameworkName
                            let outputPath = outputDir.appendingPathComponent(frameworkName)
                            let exists = fileSystem.exists(outputPath)
                            guard exists else { return nil }

                            let expectedCacheKey = try await cacheSystem.calculateCacheKey(of: target)
                            let isValidCache = await cacheSystem.existsValidCache(cacheKey: expectedCacheKey)
                            guard isValidCache else {
                                logger.warning("⚠️ Existing \(frameworkName) is outdated.", metadata: .color(.yellow))
                                logger.info("🗑️ Delete \(frameworkName)", metadata: .color(.red))
                                try fileSystem.removeFileTree(outputPath)

                                return nil
                            }

                            let expectedCacheKeyHash = try expectedCacheKey.calculateChecksum()
                            logger.info(
                                // swiftlint:disable:next line_length
                                "✅ Valid \(product.target.name).xcframework (\(expectedCacheKeyHash)) exists. Skip restoring or building.", metadata: .color(.green)
                            )
                            return target
                        } catch {
                            return nil
                        }
                    }
                }
                for await case let target? in group {
                    validFrameworks.insert(target)
                }
            }
        }
        return validFrameworks
    }

    private func restoreAllAvailableCachesIfNeeded(
        availableTargets: Set<CacheSystem.CacheTarget>,
        to storages: [any CacheStorage],
        cacheSystem: CacheSystem
    ) async -> Set<CacheSystem.CacheTarget> {
        var remainingTargets = availableTargets
        var restored: Set<CacheSystem.CacheTarget> = []

        for index in storages.indices {
            let storage = storages[index]

            let logSuffix = "[\(index)] \(storage.displayName)"
            if index == storages.startIndex {
                logger.info(
                    "▶️ Starting restoration with cache storage: \(logSuffix)",
                    metadata: .color(.green)
                )
            } else {
                logger.info(
                    "⏭️ Falling back to next cache storage: \(logSuffix)",
                    metadata: .color(.green)
                )
            }

            let restoredPerStorage = await restoreCaches(
                for: remainingTargets,
                from: storage,
                cacheSystem: cacheSystem
            )
            restored.formUnion(restoredPerStorage)

            logger.info(
                "⏸️ Restoration finished with cache storage: \(logSuffix)",
                metadata: .color(.green)
            )

            remainingTargets.subtract(restoredPerStorage)
            // If all frameworks are successfully restored, we don't need to proceed to next cache storage.
            if remainingTargets.isEmpty {
                break
            }
        }

        logger.info("⏹️ Restoration finished", metadata: .color(.green))
        return restored
    }

    private func restoreCaches(
        for targets: Set<CacheSystem.CacheTarget>,
        from cacheStorage: any CacheStorage,
        cacheSystem: CacheSystem
    ) async -> Set<CacheSystem.CacheTarget> {
        let chunked = targets.chunks(ofCount: cacheStorage.parallelNumber ?? CacheSystem.defaultParalellNumber)

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
            cacheStorage: any CacheStorage
        ) async throws -> Bool {
            let product = target.buildProduct
            let frameworkName = product.frameworkName

            let expectedCacheKey = try await cacheSystem.calculateCacheKey(of: target)
            let expectedCacheKeyHash = try expectedCacheKey.calculateChecksum()

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
                logger.info("ℹ️ Cache not found for \(frameworkName) (\(expectedCacheKeyHash)) from cache storage.", metadata: .color(.green))
                return false
            }
        }
    }

    private func buildTargets(_ targets: DependencyGraph<CacheSystem.CacheTarget>) async -> TargetBuildResult {
        var builtTargets = OrderedCollections.OrderedSet<CacheSystem.CacheTarget>()

        do {
            var targets = targets
            while let leafNode = targets.leafs.first {
                let buildTarget = leafNode.value
                try await buildXCFrameworks(
                    buildTarget,
                    outputDir: outputDir,
                    buildOptionsMatrix: buildOptionsMatrix
                )
                builtTargets.append(buildTarget)
                targets.remove(buildTarget)
            }
            return .completed(builtTargets: builtTargets)
        } catch {
            return .interrupted(builtTargets: builtTargets, error: error)
        }
    }

    private enum TargetBuildResult {
        case interrupted(builtTargets: OrderedCollections.OrderedSet<CacheSystem.CacheTarget>, error: any Error)
        case completed(builtTargets: OrderedCollections.OrderedSet<CacheSystem.CacheTarget>)
    }

    @discardableResult
    private func buildXCFrameworks(
        _ target: CacheSystem.CacheTarget,
        outputDir: URL,
        buildOptionsMatrix: [String: BuildOptions]
    ) async throws -> Set<CacheSystem.CacheTarget> {
        let product = target.buildProduct
        let buildOptions = target.buildOptions

        switch product.target.underlying.type {
        case .regular:
            let compiler = PIFCompiler(
                descriptionPackage: descriptionPackage,
                buildOptions: buildOptions,
                buildOptionsMatrix: buildOptionsMatrix
            )
            try await compiler.createXCFramework(buildProduct: product,
                                                 outputDirectory: outputDir,
                                                 overwrite: overwrite)
        case .binary:
            let binaryExtractor = BinaryExtractor(
                descriptionPackage: descriptionPackage,
                outputDirectory: outputDir,
                fileSystem: fileSystem
            )
            try binaryExtractor.extract(of: product.target, overwrite: overwrite)
            logger.info("✅ Copy \(product.target.c99name).xcframework", metadata: .color(.green))
        default:
            fatalError("Unexpected target type \(product.target.underlying.type)")
        }

        return []
    }

    private func cacheFrameworksIfNeeded(_ targets: Set<CacheSystem.CacheTarget>, cacheSystem: CacheSystem) async {
        let storagesWithProducer = cachePolicies.storages(for: .producer)
        if !storagesWithProducer.isEmpty {
            await cacheSystem.cacheFrameworks(targets, to: storagesWithProducer)
        }
    }

    private func generateVersionFile(for target: CacheSystem.CacheTarget, using cacheSystem: CacheSystem) async {
        do {
            try await cacheSystem.generateVersionFile(for: target)
        } catch {
            logger.warning("⚠️ Could not create VersionFile. This framework will not be cached.", metadata: .color(.yellow))
        }
    }

    internal func shareRestoredCachesToProducers(
        _ restoredTargets: Set<CacheSystem.CacheTarget>,
        cacheSystem: CacheSystem
    ) async {
        let storagesWithProducer = cachePolicies.storages(for: .producer)
        guard !storagesWithProducer.isEmpty else { return }

        logger.info(
            "🔄 Sharing \(restoredTargets.count) restored framework(s) to other cache storages",
            metadata: .color(.blue)
        )

        for storage in storagesWithProducer {
            await shareCachesToStorage(restoredTargets, to: storage, cacheSystem: cacheSystem)
        }
    }

    private func shareCachesToStorage(
        _ targets: Set<CacheSystem.CacheTarget>,
        to storage: any CacheStorage,
        cacheSystem: CacheSystem
    ) async {
        let chunked = targets.chunks(ofCount: storage.parallelNumber ?? CacheSystem.defaultParalellNumber)

        for chunk in chunked {
            await withTaskGroup(of: Void.self) { group in
                for target in chunk {
                    group.addTask {
                        do {
                            let cacheKey = try await cacheSystem.calculateCacheKey(of: target)
                            let hasCache = try await storage.existsValidCache(for: cacheKey)
                            guard !hasCache else { return }

                            let frameworkName = target.buildProduct.frameworkName
                            let frameworkPath = outputDir.appendingPathComponent(frameworkName)

                            logger.info(
                                "🔄 Share \(frameworkName) to cache storage: \(storage.displayName)",
                                metadata: .color(.blue)
                            )
                            try await storage.cacheFramework(frameworkPath, for: cacheKey)
                        } catch {
                            logger.warning(
                                "⚠️ Failed to share cache to \(storage.displayName): \(error.localizedDescription)",
                                metadata: .color(.yellow)
                            )
                        }
                    }
                }
                await group.waitForAll()
            }
        }
    }
}

extension [Runner.Options.CachePolicy] {
    fileprivate func storages(for actor: Runner.Options.CachePolicy.CacheActorKind) -> [any CacheStorage] {
        reduce(into: []) { result, cachePolicy in
            if cachePolicy.actors.contains(actor) {
                result.append(cachePolicy.storage)
            }
        }
    }
}
