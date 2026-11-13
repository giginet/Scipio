import Foundation
import CacheStorage
import Collections
import PackageManifestKit

struct FrameworkProducer {
    private let descriptionPackage: DescriptionPackage
    private let baseBuildOptions: BuildOptions
    private let buildOptionsMatrix: [String: BuildOptions]
    private let cachePolicies: [Runner.Options.FrameworkCachePolicy]
    private let overwrite: Bool
    private let outputDir: URL
    private let fileSystem: any FileSystem
    private let macroContext: MacroBuildContext?

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
        cachePolicies: [Runner.Options.FrameworkCachePolicy],
        overwrite: Bool,
        outputDir: URL,
        macroContext: MacroBuildContext? = nil,
        fileSystem: any FileSystem = LocalFileSystem.default
    ) {
        self.descriptionPackage = descriptionPackage
        self.baseBuildOptions = buildOptions
        self.buildOptionsMatrix = buildOptionsMatrix
        self.cachePolicies = cachePolicies
        self.overwrite = overwrite
        self.outputDir = outputDir
        self.macroContext = macroContext
        self.fileSystem = fileSystem
    }

    func produce() async throws {
        try await clean()

        let buildProductDependencyGraph = try descriptionPackage.resolveBuildProductDependencyGraph()

        try await processAllTargets(buildProductDependencyGraph: buildProductDependencyGraph)
    }

    private func overriddenBuildOption(for buildProduct: BuildProduct) -> BuildOptions {
        overriddenBuildOption(forTargetNamed: buildProduct.target.name)
    }

    private func overriddenBuildOption(forTargetNamed targetName: String) -> BuildOptions {
        buildOptionsMatrix[targetName] ?? baseBuildOptions
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
            try await macroContext?.produce()
            return
        }

        let targetGraph = buildProductDependencyGraph.map { buildProduct in
            let buildOptionsForProduct = overriddenBuildOption(for: buildProduct)
            return CacheSystem.CacheTarget(
                buildProduct: buildProduct,
                buildOptions: buildOptionsForProduct
            )
        }

        let allTargets = targetGraph.allNodes.map(\.value)

        let cacheSystem = CacheSystem(outputDirectory: outputDir)
        let cacheKeys: [CacheSystem.CacheTarget: SwiftPMCacheKey]

        let dependencyGraphToBuild: DependencyGraph<CacheSystem.CacheTarget>
        if cachePolicies.isEmpty {
            // no-op because cache is disabled
            cacheKeys = [:]
            dependencyGraphToBuild = targetGraph
        } else {
            let cached = try await prepareFrameworkCache(for: targetGraph, cacheSystem: cacheSystem)
            cacheKeys = cached.cacheKeys
            dependencyGraphToBuild = cached.graph
        }

        try await macroContext?.produce()
        let targetBuildResult = await buildTargets(
            dependencyGraphToBuild,
            cacheSystem: cacheSystem,
            cacheKeys: cacheKeys
        )

        // Keep the historical "cache feature is fully off" behavior when no cache policy is provided:
        // no restore, no cache save, and no version file generation.
        guard !cachePolicies.isEmpty else {
            if let error = targetBuildResult.error {
                throw error
            }
            return
        }

        await shareRestoredCachesToProducers(
            restoredSetsToSourceStorage: targetBuildResult.restoredSetsToSourceStorage,
            cacheSystem: cacheSystem,
            cacheKeys: cacheKeys
        )

        let deferredProducers = cachePolicies.storages(for: .producer).filter { !($0 is LocalDiskCacheStorage) }
        await cacheSystem.cacheFrameworks(
            Set(targetBuildResult.builtTargets), cacheKeys: cacheKeys, to: deferredProducers
        )

        if shouldGenerateVersionFile {
            // Versionfiles should be generate for all targets
            for target in allTargets {
                await generateVersionFile(for: target, using: cacheSystem, cacheKeys: cacheKeys)
            }
        }

        if let error = targetBuildResult.error {
            throw error
        }
    }

    private func validateExistingFrameworks(
        availableTargets: Set<CacheSystem.CacheTarget>,
        cacheSystem: CacheSystem,
        cacheKeys: [CacheSystem.CacheTarget: SwiftPMCacheKey],
        uncacheableMacroTargets: Set<String>
    ) async -> Set<CacheSystem.CacheTarget> {
        let chunked = availableTargets.chunks(ofCount: CacheSystem.defaultParallelNumber)

        var validFrameworks: Set<CacheSystem.CacheTarget> = []
        for chunk in chunked {
            await withTaskGroup(of: CacheSystem.CacheTarget?.self) { group in
                for target in chunk {
                    group.addTask { [outputDir, fileSystem] in
                        do {
                            let product = target.buildProduct
                            let frameworkName = product.frameworkName
                            let outputPath = outputDir.appending(component: frameworkName)
                            let exists = fileSystem.exists(outputPath)
                            if cacheKeys[target] == nil && uncacheableMacroTargets.contains(product.target.name) {
                                if exists {
                                    try fileSystem.removeFileTree(outputPath)
                                }
                                let versionPath = outputDir.appending(component: ".\(product.target.name).version")
                                if fileSystem.exists(versionPath) {
                                    try fileSystem.removeFileTree(versionPath)
                                }
                                return nil
                            }
                            guard exists else { return nil }

                            guard let expectedCacheKey = cacheKeys[target] else { return nil }
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
        to storages: [any FrameworkCacheStorage],
        cacheSystem: CacheSystem,
        cacheKeys: [CacheSystem.CacheTarget: SwiftPMCacheKey]
    ) async -> [Set<CacheSystem.CacheTarget>: any FrameworkCacheStorage] {
        var remainingTargets = availableTargets
        var restoredSetsToSourceStorage: [Set<CacheSystem.CacheTarget>: any FrameworkCacheStorage] = [:]

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
                cacheSystem: cacheSystem,
                cacheKeys: cacheKeys
            )

            // Record which storage restored which set of targets
            if !restoredPerStorage.isEmpty {
                restoredSetsToSourceStorage[restoredPerStorage] = storage
            }

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
        return restoredSetsToSourceStorage
    }

    private func restoreCaches(
        for targets: Set<CacheSystem.CacheTarget>,
        from cacheStorage: any FrameworkCacheStorage,
        cacheSystem: CacheSystem,
        cacheKeys: [CacheSystem.CacheTarget: SwiftPMCacheKey]
    ) async -> Set<CacheSystem.CacheTarget> {
        let chunked = targets.chunks(ofCount: cacheStorage.parallelNumber ?? CacheSystem.defaultParallelNumber)

        var restored: Set<CacheSystem.CacheTarget> = []
        for chunk in chunked {
            await withTaskGroup(of: CacheSystem.CacheTarget?.self) { group in
                for target in chunk {
                    group.addTask {
                        do {
                            let restored = try await Restorer.restore(
                                target: target,
                                cacheKey: cacheKeys[target],
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

    private func buildTargets(
        _ targets: DependencyGraph<CacheSystem.CacheTarget>,
        cacheSystem: CacheSystem,
        cacheKeys: [CacheSystem.CacheTarget: SwiftPMCacheKey]
    ) async -> TargetBuildResult {
        var result = TargetBuildResult()
        let localStorages = cachePolicies.storages(for: .consumer).compactMap { $0 as? LocalDiskCacheStorage }
        let localProducers = cachePolicies.storages(for: .producer).filter { $0 is LocalDiskCacheStorage }

        await withTaskGroup(of: Void.self) { copies in
            var pendingCopies = 0
            do {
                var targets = targets
                while let leafNode = targets.leafs.first {
                    let buildTarget = leafNode.value
                    let sourceStorage = await restoreLocalCache(
                        for: buildTarget, from: localStorages, cacheSystem: cacheSystem, cacheKey: cacheKeys[buildTarget]
                    )
                    if let sourceStorage {
                        result.restoredSetsToSourceStorage[[buildTarget]] = sourceStorage
                    } else {
                        try await buildXCFrameworks(
                            buildTarget, outputDir: outputDir, buildOptionsMatrix: buildOptionsMatrix
                        )
                        result.builtTargets.append(buildTarget)
                        if !localProducers.isEmpty {
                            if pendingCopies == CacheSystem.defaultParallelNumber {
                                await copies.next()
                                pendingCopies -= 1
                            }
                            copies.addTask {
                                await cacheSystem.cacheFrameworks([buildTarget], cacheKeys: cacheKeys, to: localProducers)
                            }
                            pendingCopies += 1
                        }
                    }
                    targets.remove(buildTarget)
                }
            } catch {
                result.error = error
            }
        }
        return result
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
                buildOptionsMatrix: buildOptionsMatrix,
                macroPlan: macroContext?.plan,
                macroPlugins: macroContext?.plugins ?? [:],
                keepPublicHeadersStructure: { [baseBuildOptions, buildOptionsMatrix] targetName in
                    (buildOptionsMatrix[targetName] ?? baseBuildOptions).keepPublicHeadersStructure
                }
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
        case .system:
            try await packageSystemLibrary(product, buildOptions: buildOptions, outputDir: outputDir)
        default:
            // Unreachable while the build-product graph only carries producible kinds.
            throw Error.unsupportedTargetType(
                targetName: product.target.name,
                type: product.target.underlying.type
            )
        }

        return []
    }

    private func generateVersionFile(
        for target: CacheSystem.CacheTarget,
        using cacheSystem: CacheSystem,
        cacheKeys: [CacheSystem.CacheTarget: SwiftPMCacheKey]
    ) async {
        let frameworkName = target.buildProduct.frameworkName
        guard let cacheKey = cacheKeys[target] else {
            logger.warning(
                "⚠️ Could not create VersionFile for \(frameworkName). This framework will not be cached.",
                metadata: .color(.yellow)
            )
            return
        }

        do {
            try await cacheSystem.generateVersionFile(for: target, cacheKey: cacheKey)
        } catch {
            logger.warning(
                "⚠️ Could not create VersionFile for \(frameworkName). This framework will not be cached.",
                metadata: .color(.yellow)
            )
        }
    }

}

extension FrameworkProducer {
    private func restoreLocalCache(
        for target: CacheSystem.CacheTarget,
        from storages: [LocalDiskCacheStorage],
        cacheSystem: CacheSystem,
        cacheKey: SwiftPMCacheKey?
    ) async -> LocalDiskCacheStorage? {
        for storage in storages where (try? await Restorer.restore(
            target: target, cacheKey: cacheKey, cacheSystem: cacheSystem, cacheStorage: storage, logCacheMiss: false
        )) == true {
            return storage
        }
        return nil
    }

    private func shareRestoredCachesToProducers(
        restoredSetsToSourceStorage: [Set<CacheSystem.CacheTarget>: any FrameworkCacheStorage],
        cacheSystem: CacheSystem,
        cacheKeys: [CacheSystem.CacheTarget: SwiftPMCacheKey]
    ) async {
        let allRestoredTargets = Set(restoredSetsToSourceStorage.keys.joined())
        let storagesWithProducer = cachePolicies.storages(for: .producer)
        guard !allRestoredTargets.isEmpty, !storagesWithProducer.isEmpty else { return }

        logger.info(
            "🔄 Sharing \(allRestoredTargets.count) restored framework(s) to other cache storages",
            metadata: .color(.blue)
        )

        for storage in storagesWithProducer {
            // Filter targets to exclude those that were restored from this storage
            var targetsToShare = allRestoredTargets

            // Remove targets that were restored from this storage
            for (restoredSet, sourceStorage) in restoredSetsToSourceStorage where Self.areStoragesEqual(sourceStorage, storage) {
                targetsToShare.subtract(restoredSet)
            }

            if !targetsToShare.isEmpty {
                await shareCachesToStorage(targetsToShare, to: storage, cacheSystem: cacheSystem, cacheKeys: cacheKeys)
            }
        }

        logger.info("⏹️ Sharing to other cache storages finished", metadata: .color(.green))
    }

}

extension FrameworkProducer {
    private func makeMacroCacheInputs(for graph: DependencyGraph<CacheSystem.CacheTarget>) throws -> MacroCacheInputs {
        var macroChecksums: [String: [DependencyCacheKeyChecksum]] = [:]
        var uncacheableMacroTargets: Set<String> = []
        for (target, names) in macroContext?.plan.targetDependencies ?? [:] {
            for name in names {
                guard let plugin = macroContext?.plugins[name], let key = plugin.cacheKey else {
                    uncacheableMacroTargets.insert(target)
                    continue
                }
                macroChecksums[target, default: []].append(
                    DependencyCacheKeyChecksum(targetName: name, checksum: try key.calculateChecksum())
                )
            }
        }
        var uncacheableForMacro = uncacheableMacroTargets
        var pending = Deque(graph.allNodes.filter {
            uncacheableMacroTargets.contains($0.value.buildProduct.target.name)
        })
        while let node = pending.popFirst() {
            for parent in node.parents.compactMap(\.reference)
            where uncacheableForMacro.insert(parent.value.buildProduct.target.name).inserted {
                pending.append(parent)
            }
        }
        return MacroCacheInputs(
            checksumsByTarget: macroChecksums,
            uncacheableTargets: uncacheableMacroTargets,
            uncacheableTargetsIncludingDependents: uncacheableForMacro
        )
    }

    private func prepareFrameworkCache(
        for graph: DependencyGraph<CacheSystem.CacheTarget>,
        cacheSystem: CacheSystem
    ) async throws -> (graph: DependencyGraph<CacheSystem.CacheTarget>, cacheKeys: [CacheSystem.CacheTarget: SwiftPMCacheKey]) {
        var targetGraph = graph
        let macroInputs = try makeMacroCacheInputs(for: graph)
        let cacheKeys = try await cacheSystem.calculateCacheKeys(
            for: targetGraph,
            macroChecksums: macroInputs.checksumsByTarget,
            uncacheableTargets: macroInputs.uncacheableTargets
        )
        let targets = Set(targetGraph.allNodes.map(\.value))

        // Validate the existing frameworks in `outputDir` before restoration
        let valid = await validateExistingFrameworks(
            availableTargets: targets,
            cacheSystem: cacheSystem,
            cacheKeys: cacheKeys,
            uncacheableMacroTargets: macroInputs.uncacheableTargetsIncludingDependents
        )

        let storagesWithConsumer = cachePolicies.storages(for: .consumer)
        if storagesWithConsumer.isEmpty {
            // no-op
            targetGraph.remove(valid)
        } else {
            let restoredSetsToSourceStorage = await restoreAllAvailableCachesIfNeeded(
                availableTargets: targets.subtracting(valid),
                to: storagesWithConsumer,
                cacheSystem: cacheSystem,
                cacheKeys: cacheKeys
            )

            let allRestoredTargets = Set(restoredSetsToSourceStorage.keys.joined())
            await shareRestoredCachesToProducers(
                restoredSetsToSourceStorage: restoredSetsToSourceStorage,
                cacheSystem: cacheSystem,
                cacheKeys: cacheKeys
            )
            targetGraph.remove(valid.union(allRestoredTargets))
        }
        return (targetGraph, cacheKeys)
    }

    private func shareCachesToStorage(
        _ targets: Set<CacheSystem.CacheTarget>,
        to storage: any FrameworkCacheStorage,
        cacheSystem: CacheSystem,
        cacheKeys: [CacheSystem.CacheTarget: SwiftPMCacheKey]
    ) async {
        let chunked = targets.chunks(ofCount: storage.parallelNumber ?? CacheSystem.defaultParallelNumber)

        for chunk in chunked {
            await withTaskGroup(of: Void.self) { group in
                for target in chunk {
                    group.addTask { [outputDir] in
                        do {
                            guard let cacheKey = cacheKeys[target] else { return }
                            let hasCache = try await storage.existsValidCache(for: cacheKey)
                            guard !hasCache else { return }

                            let frameworkName = target.buildProduct.frameworkName
                            let frameworkPath = outputDir.appending(component: frameworkName)

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

extension FrameworkProducer {
    fileprivate func packageSystemLibrary(
        _ product: BuildProduct,
        buildOptions: BuildOptions,
        outputDir: URL
    ) async throws {
        let packager = SystemLibraryPackager(
            descriptionPackage: descriptionPackage,
            buildOptions: buildOptions,
            keepPublicHeadersStructure: { [baseBuildOptions, buildOptionsMatrix] targetName in
                (buildOptionsMatrix[targetName] ?? baseBuildOptions).keepPublicHeadersStructure
            },
            fileSystem: fileSystem
        )
        try await packager.createXCFramework(buildProduct: product,
                                             outputDirectory: outputDir,
                                             overwrite: overwrite)
    }
}

extension [Runner.Options.FrameworkCachePolicy] {
    fileprivate func storages(for actor: Runner.Options.CacheActorKind) -> [any FrameworkCacheStorage] {
        reduce(into: []) { result, cachePolicy in
            if cachePolicy.actors.contains(actor) {
                result.append(cachePolicy.storage)
            }
        }
    }
}
