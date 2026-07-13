import Foundation
import PackageManifestKit

/// A flat, index-referenced encoding of `[ResolvedPackage]` for cache storage.
///
/// The model types embed their dependencies recursively by value, so their
/// synthesized `Codable` output duplicates every shared subtree: exponential
/// in graph depth. The snapshot stores each package, module, and product
/// exactly once and references them by table index, so its size stays linear
/// in the graph size.
package struct ResolvedPackagesSnapshot: Codable, Sendable, Equatable {
    /// Bump this when the stored representation changes; a snapshot with a
    /// different version fails to restore, which storages treat as a miss.
    /// `ResolvedPackagesSnapshotTests` pins the encoded bytes of the current
    /// version with a fixture, so an unnoticed format change fails there.
    package static let currentFormatVersion = 1

    /// Deeper snapshots are rejected: consumers traverse the restored graph
    /// recursively, so a crafted, extremely deep snapshot could overflow the
    /// stack even though restoring itself is iterative.
    package static let maxDependencyDepth = 1_000

    package var formatVersion: Int
    var modules: [ModuleRecord]
    var products: [ProductRecord]
    var packages: [PackageRecord]

    /// A `ResolvedModule` whose dependencies are stored as edges.
    struct ModuleRecord: Codable, Sendable, Equatable {
        var underlying: PackageManifestKit.Target
        var dependencies: [DependencyRecord]
        var localPackageURL: URL
        var packageID: PackageID
        var resolvedModuleType: ResolvedModuleType

        var identity: ResolvedIdentity {
            ResolvedIdentity(packageID: packageID, name: underlying.name)
        }
    }

    /// A `ResolvedProduct` whose modules are stored as indices into `modules`.
    struct ProductRecord: Codable, Sendable, Equatable {
        var underlying: PackageManifestKit.Product
        var moduleIndices: [Int]
        var type: ProductType
        var packageID: PackageID

        var identity: ResolvedIdentity {
            ResolvedIdentity(packageID: packageID, name: underlying.name)
        }
    }

    /// A `ResolvedPackage` whose targets and products are stored as indices.
    /// The package ID is not stored; `ResolvedPackage.init` re-derives it.
    struct PackageRecord: Codable, Sendable, Equatable {
        var packageIdentity: String
        var manifest: Manifest
        var resolvedPackageKind: PackageKind
        var path: String
        var pinState: Pin.State?
        var targetIndices: [Int]
        var productIndices: [Int]
    }

    /// A dependency edge pointing at a row of `modules` or `products`.
    struct DependencyRecord: Codable, Sendable, Equatable {
        enum Kind: String, Codable, Sendable {
            case module
            case product
        }

        var kind: Kind
        var index: Int
        var conditions: [PackageCondition]
    }

    /// A structural inconsistency found while restoring a snapshot.
    /// Storages should treat these errors as a cache miss.
    package enum RestoreError: LocalizedError, Equatable {
        case unsupportedFormatVersion(found: Int, supported: Int)
        case invalidModuleReference(index: Int)
        case invalidProductReference(index: Int)
        case duplicateModuleIdentity(ResolvedIdentity)
        case duplicateProductIdentity(ResolvedIdentity)
        case duplicatePackageIdentity(String)
        case dependencyCycleDetected
        case dependencyChainTooDeep(depth: Int)

        package var errorDescription: String? {
            switch self {
            case .unsupportedFormatVersion(let found, let supported):
                "Unsupported snapshot format version \(found) (supported: \(supported))"
            case .invalidModuleReference(let index):
                "A reference points at module #\(index), which does not exist"
            case .invalidProductReference(let index):
                "A reference points at product #\(index), which does not exist"
            case .duplicateModuleIdentity(let identity):
                "Module \(identity.name) in \(identity.packageID.packageIdentity) is stored more than once"
            case .duplicateProductIdentity(let identity):
                "Product \(identity.name) in \(identity.packageID.packageIdentity) is stored more than once"
            case .duplicatePackageIdentity(let packageIdentity):
                "Package \(packageIdentity) is stored more than once"
            case .dependencyCycleDetected:
                "The stored dependency graph contains a cycle"
            case .dependencyChainTooDeep(let depth):
                "The stored dependency graph is deeper than the supported maximum (\(depth) > \(maxDependencyDepth))"
            }
        }
    }
}

// MARK: - Flattening

extension ResolvedPackagesSnapshot {
    /// Flattening cannot fail: value semantics make cycles unrepresentable in
    /// the input. The traversal is iterative because restored graphs can be
    /// `maxDependencyDepth` deep, too deep for recursion.
    package init(resolvedPackages: [ResolvedPackage]) {
        var flattener = Flattener()
        let packageRecords = resolvedPackages.map { flattener.flatten($0) }
        flattener.fillPendingEdges()

        self.formatVersion = Self.currentFormatVersion
        self.modules = flattener.modules
        self.products = flattener.products
        self.packages = packageRecords
    }

    private struct Flattener {
        private(set) var modules: [ModuleRecord] = []
        private(set) var products: [ProductRecord] = []
        private var moduleIndicesByIdentity: [ResolvedIdentity: Int] = [:]
        private var productIndicesByIdentity: [ResolvedIdentity: Int] = [:]
        // Records whose edges are not filled in yet; worklists instead of recursion.
        private var pendingModules: [(module: ResolvedModule, index: Int)] = []
        private var pendingProducts: [(product: ResolvedProduct, index: Int)] = []

        mutating func flatten(_ package: ResolvedPackage) -> PackageRecord {
            PackageRecord(
                packageIdentity: package.id.packageIdentity,
                manifest: package.manifest,
                resolvedPackageKind: package.resolvedPackageKind,
                path: package.path,
                pinState: package.pinState,
                targetIndices: package.targets.map { registerIndex(of: $0) },
                productIndices: package.products.map { registerIndex(of: $0) }
            )
        }

        mutating func fillPendingEdges() {
            var nextModule = 0
            var nextProduct = 0
            while nextModule < pendingModules.count || nextProduct < pendingProducts.count {
                if nextModule < pendingModules.count {
                    let (module, index) = pendingModules[nextModule]
                    nextModule += 1
                    modules[index].dependencies = module.dependencies.map { dependency in
                        switch dependency {
                        case .module(let module, let conditions):
                            DependencyRecord(kind: .module, index: registerIndex(of: module), conditions: conditions)
                        case .product(let product, let conditions):
                            DependencyRecord(kind: .product, index: registerIndex(of: product), conditions: conditions)
                        }
                    }
                } else {
                    let (product, index) = pendingProducts[nextProduct]
                    nextProduct += 1
                    products[index].moduleIndices = product.modules.map { registerIndex(of: $0) }
                }
            }
        }

        /// Returns the module's table index, registering it on first visit so
        /// that shared modules are stored only once.
        private mutating func registerIndex(of module: ResolvedModule) -> Int {
            let identity = module.identity
            if let index = moduleIndicesByIdentity[identity] {
                return index
            }

            let index = modules.count
            moduleIndicesByIdentity[identity] = index
            modules.append(
                ModuleRecord(
                    underlying: module.underlying,
                    dependencies: [],
                    localPackageURL: module.localPackageURL,
                    packageID: module.packageID,
                    resolvedModuleType: module.resolvedModuleType
                )
            )
            pendingModules.append((module, index))
            return index
        }

        private mutating func registerIndex(of product: ResolvedProduct) -> Int {
            let identity = product.identity
            if let index = productIndicesByIdentity[identity] {
                return index
            }

            let index = products.count
            productIndicesByIdentity[identity] = index
            products.append(
                ProductRecord(
                    underlying: product.underlying,
                    moduleIndices: [],
                    type: product.type,
                    packageID: product.packageID
                )
            )
            pendingProducts.append((product, index))
            return index
        }
    }
}

// MARK: - Restoring

extension ResolvedPackagesSnapshot {
    /// Rebuilds the resolved package graph, validating every structural
    /// property of the snapshot along the way.
    package func restoreResolvedPackages() throws -> [ResolvedPackage] {
        try Restorer(snapshot: self).restore()
    }

    /// Rebuilds the graph iteratively (Kahn's algorithm), so a hostile deep
    /// snapshot cannot overflow the stack.
    private struct Restorer {
        private let snapshot: ResolvedPackagesSnapshot
        private let moduleCount: Int
        private let productCount: Int

        init(snapshot: ResolvedPackagesSnapshot) {
            self.snapshot = snapshot
            self.moduleCount = snapshot.modules.count
            self.productCount = snapshot.products.count
        }

        func restore() throws -> [ResolvedPackage] {
            guard snapshot.formatVersion == ResolvedPackagesSnapshot.currentFormatVersion else {
                throw RestoreError.unsupportedFormatVersion(
                    found: snapshot.formatVersion,
                    supported: ResolvedPackagesSnapshot.currentFormatVersion
                )
            }
            try validateUniqueIdentities()
            try validateReferences()

            let (modules, products) = try buildModulesAndProducts()
            return snapshot.packages.map { record in
                ResolvedPackage(
                    manifest: record.manifest,
                    resolvedPackageKind: record.resolvedPackageKind,
                    packageIdentity: record.packageIdentity,
                    pinState: record.pinState,
                    path: record.path,
                    targets: record.targetIndices.map { modules[$0] },
                    products: record.productIndices.map { products[$0] }
                )
            }
        }

        /// One record per identity is the invariant the identity-based
        /// `Hashable` of the model types relies on.
        private func validateUniqueIdentities() throws {
            var moduleIdentities = Set<ResolvedIdentity>()
            for module in snapshot.modules {
                guard moduleIdentities.insert(module.identity).inserted else {
                    throw RestoreError.duplicateModuleIdentity(module.identity)
                }
            }

            var productIdentities = Set<ResolvedIdentity>()
            for product in snapshot.products {
                guard productIdentities.insert(product.identity).inserted else {
                    throw RestoreError.duplicateProductIdentity(product.identity)
                }
            }

            var packageIdentities = Set<String>()
            for package in snapshot.packages {
                guard packageIdentities.insert(package.packageIdentity).inserted else {
                    throw RestoreError.duplicatePackageIdentity(package.packageIdentity)
                }
            }
        }

        /// Load-bearing: everything after this pass indexes the tables without
        /// bounds checks, so a corrupt snapshot must be rejected here to
        /// degrade to a miss instead of a crash.
        private func validateReferences() throws {
            for module in snapshot.modules {
                for dependency in module.dependencies {
                    switch dependency.kind {
                    case .module:
                        try validateModuleReference(dependency.index)
                    case .product:
                        try validateProductReference(dependency.index)
                    }
                }
            }
            for product in snapshot.products {
                for index in product.moduleIndices {
                    try validateModuleReference(index)
                }
            }
            for package in snapshot.packages {
                for index in package.targetIndices {
                    try validateModuleReference(index)
                }
                for index in package.productIndices {
                    try validateProductReference(index)
                }
            }
        }

        private func validateModuleReference(_ index: Int) throws {
            guard snapshot.modules.indices.contains(index) else {
                throw RestoreError.invalidModuleReference(index: index)
            }
        }

        private func validateProductReference(_ index: Int) throws {
            guard snapshot.products.indices.contains(index) else {
                throw RestoreError.invalidProductReference(index: index)
            }
        }

        /// Materializes all modules and products in dependency order, over one
        /// combined node set (modules occupy `0..<moduleCount`, products the
        /// following indices). Nodes left unprocessed at the end form a cycle.
        private func buildModulesAndProducts() throws -> (modules: [ResolvedModule], products: [ResolvedProduct]) {
            let nodeCount = moduleCount + productCount
            var pendingDependencies = [Int](repeating: 0, count: nodeCount)
            var dependents = [[Int]](repeating: [], count: nodeCount)

            for (index, module) in snapshot.modules.enumerated() {
                pendingDependencies[index] = module.dependencies.count
                for dependency in module.dependencies {
                    dependents[nodeIndex(of: dependency)].append(index)
                }
            }
            for (index, product) in snapshot.products.enumerated() {
                let node = moduleCount + index
                pendingDependencies[node] = product.moduleIndices.count
                for moduleIndex in product.moduleIndices {
                    dependents[moduleIndex].append(node)
                }
            }

            var builtModules = [ResolvedModule?](repeating: nil, count: moduleCount)
            var builtProducts = [ResolvedProduct?](repeating: nil, count: productCount)
            var depths = [Int](repeating: 0, count: nodeCount)
            var readyNodes = (0..<nodeCount).filter { pendingDependencies[$0] == 0 }
            var nextReadyIndex = 0

            while nextReadyIndex < readyNodes.count {
                let node = readyNodes[nextReadyIndex]
                nextReadyIndex += 1

                let dependencyNodes: [Int]
                if node < moduleCount {
                    dependencyNodes = snapshot.modules[node].dependencies.map { nodeIndex(of: $0) }
                    builtModules[node] = try buildModule(at: node, from: builtModules, and: builtProducts)
                } else {
                    let productIndex = node - moduleCount
                    dependencyNodes = snapshot.products[productIndex].moduleIndices
                    builtProducts[productIndex] = try buildProduct(at: productIndex, from: builtModules)
                }

                let depth = 1 + (dependencyNodes.map { depths[$0] }.max() ?? 0)
                guard depth <= ResolvedPackagesSnapshot.maxDependencyDepth else {
                    throw RestoreError.dependencyChainTooDeep(depth: depth)
                }
                depths[node] = depth

                for dependent in dependents[node] {
                    pendingDependencies[dependent] -= 1
                    if pendingDependencies[dependent] == 0 {
                        readyNodes.append(dependent)
                    }
                }
            }

            let modules = builtModules.compactMap { $0 }
            let products = builtProducts.compactMap { $0 }
            guard modules.count == moduleCount, products.count == productCount else {
                throw RestoreError.dependencyCycleDetected
            }
            return (modules, products)
        }

        private func nodeIndex(of dependency: DependencyRecord) -> Int {
            switch dependency.kind {
            case .module: dependency.index
            case .product: moduleCount + dependency.index
            }
        }

        private func buildModule(
            at index: Int,
            from builtModules: [ResolvedModule?],
            and builtProducts: [ResolvedProduct?]
        ) throws -> ResolvedModule {
            let record = snapshot.modules[index]
            let dependencies: [ResolvedModule.Dependency] = try record.dependencies.map { dependency in
                // Dependencies of a ready node are always materialized.
                switch dependency.kind {
                case .module:
                    guard let module = builtModules[dependency.index] else {
                        throw RestoreError.dependencyCycleDetected
                    }
                    return .module(module, conditions: dependency.conditions)
                case .product:
                    guard let product = builtProducts[dependency.index] else {
                        throw RestoreError.dependencyCycleDetected
                    }
                    return .product(product, conditions: dependency.conditions)
                }
            }
            return ResolvedModule(
                underlying: record.underlying,
                dependencies: dependencies,
                localPackageURL: record.localPackageURL,
                packageID: record.packageID,
                resolvedModuleType: record.resolvedModuleType
            )
        }

        private func buildProduct(at index: Int, from builtModules: [ResolvedModule?]) throws -> ResolvedProduct {
            let record = snapshot.products[index]
            let modules: [ResolvedModule] = try record.moduleIndices.map { moduleIndex in
                guard let module = builtModules[moduleIndex] else {
                    throw RestoreError.dependencyCycleDetected
                }
                return module
            }
            return ResolvedProduct(
                underlying: record.underlying,
                modules: modules,
                type: record.type,
                packageID: record.packageID
            )
        }
    }
}
