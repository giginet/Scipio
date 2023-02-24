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

    private var isCacheEnabled: Bool {
        switch cacheMode {
        case .disabled: return false
        case .project, .storage: return true
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
            targets: targets.filter { [.library, .binary].contains($0.target.type) }
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

    private func processAllTargets(targets: [BuildProduct]) async throws {
        guard !targets.isEmpty else {
            return
        }

        for product in targets {
            assert([.library, .binary].contains(product.target.type))
            let buildOptionsForProduct = overriddenBuildOption(for: product)

            let cacheSystem = CacheSystem(descriptionPackage: descriptionPackage,
                                          buildOptions: buildOptionsForProduct,
                                          outputDirectory: outputDir,
                                          storage: cacheStorage)

            try await prepareXCFrameworkIfNeeded(
                product,
                buildOptions: buildOptionsForProduct,
                outputDir: outputDir,
                cacheSystem: cacheSystem
            )

            if isCacheEnabled {
                let outputPath = outputDir.appendingPathComponent(product.frameworkName)
                try? await cacheSystem.cacheFramework(product, at: outputPath)

                if case .prepareDependencies = descriptionPackage.mode {
                    try await generateVersionFile(for: product, using: cacheSystem)
                }
            }
        }
    }

    private func prepareXCFrameworkIfNeeded(
        _ product: BuildProduct,
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
        }
    }

    private func generateVersionFile(for product: BuildProduct, using cacheSystem: CacheSystem) async throws {
        do {
            try await cacheSystem.generateVersionFile(for: product)
        } catch {
            logger.warning("⚠️ Could not create VersionFile. This framework will not be cached.", metadata: .color(.yellow))
        }
    }
}
