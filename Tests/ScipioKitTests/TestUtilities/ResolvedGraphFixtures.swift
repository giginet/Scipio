import Foundation
import PackageManifestKit
@testable import ScipioKitCore

/// Builds small synthetic resolved graphs for tests.
///
/// `PackageManifestKit` types don't provide public memberwise initializers,
/// so the manifest-side values are constructed by decoding minimal JSON.
enum ResolvedGraphFixtures {
    /// The encoder configuration `LocalDiskCacheStorage` uses, for comparing
    /// snapshots byte-wise in tests.
    static func makeCanonicalJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func packageURLString(_ identity: String) -> String {
        "https://github.com/example/\(identity).git"
    }

    static func packageID(_ identity: String = "example-package") -> PackageID {
        PackageID(
            packageKind: .remoteSourceControl(packageURLString(identity)),
            packageIdentity: identity
        )
    }

    static func target(name: String) throws -> Target {
        try decode(
            Target.self,
            fromObject: [
                "name": name,
                "packageAccess": false,
                "resources": [Any](),
                "exclude": [Any](),
                "dependencies": [Any](),
                "settings": [Any](),
                "type": "regular",
            ]
        )
    }

    static func product(name: String, targets: [String]) throws -> Product {
        try decode(
            Product.self,
            fromObject: [
                "name": name,
                "targets": targets,
                "type": ["library": ["automatic"]],
            ]
        )
    }

    static func manifest(identity: String) throws -> Manifest {
        try decode(
            Manifest.self,
            fromObject: [
                "name": identity,
                "toolsVersion": ["_version": "6.0.0"],
                "dependencies": [Any](),
                "products": [Any](),
                "targets": [Any](),
                "packageKind": ["remoteSourceControl": [packageURLString(identity)]],
            ]
        )
    }

    static func module(
        name: String,
        packageID: PackageID? = nil,
        dependencies: [ResolvedModule.Dependency] = [],
        resolvedModuleType: ResolvedModuleType = .swift
    ) throws -> ResolvedModule {
        ResolvedModule(
            underlying: try target(name: name),
            dependencies: dependencies,
            localPackageURL: URL(filePath: "/tmp/example-package"),
            packageID: packageID ?? Self.packageID(),
            resolvedModuleType: resolvedModuleType
        )
    }

    static func resolvedProduct(
        name: String,
        modules: [ResolvedModule],
        packageID: PackageID? = nil
    ) throws -> ResolvedProduct {
        ResolvedProduct(
            underlying: try product(name: name, targets: modules.map(\.underlying.name)),
            modules: modules,
            type: .library(.automatic),
            packageID: packageID ?? Self.packageID()
        )
    }

    static func package(
        identity: String = "example-package",
        targets: [ResolvedModule],
        products: [ResolvedProduct] = [],
        pinState: Pin.State? = nil
    ) throws -> ResolvedPackage {
        ResolvedPackage(
            manifest: try manifest(identity: identity),
            resolvedPackageKind: .remoteSourceControl(packageURLString(identity)),
            packageIdentity: identity,
            pinState: pinState,
            path: "/tmp/\(identity)",
            targets: targets,
            products: products
        )
    }

    /// Builds a package whose targets form a diamond-shaped chain: every level
    /// depends on the next level twice, once directly as a module dependency
    /// (with a platform condition) and once through a product wrapping the
    /// same module. Any traversal that expands the graph into a tree doubles
    /// its work per level (~2^depth paths in total), while the graph itself
    /// stays linear: the worst-case shape for structural hashing/encoding.
    static func diamondChainPackage(depth: Int) throws -> ResolvedPackage {
        let packageID = packageID()
        var current = try module(name: "Module0", packageID: packageID)
        var modules = [current]
        var products: [ResolvedProduct] = []

        for level in 1..<depth {
            let wrappingProduct = try resolvedProduct(
                name: "Product\(level - 1)",
                modules: [current],
                packageID: packageID
            )
            current = try module(
                name: "Module\(level)",
                packageID: packageID,
                dependencies: [
                    .module(current, conditions: [PackageCondition(platformNames: ["ios"], config: "debug")]),
                    .product(wrappingProduct, conditions: []),
                ]
            )
            products.append(wrappingProduct)
            modules.append(current)
        }

        return try package(
            targets: modules,
            products: products,
            pinState: Pin.State(revision: "0123456789abcdef", version: "1.0.0")
        )
    }

    private static func decode<T: Decodable>(_ type: T.Type, fromObject object: [String: Any]) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(type, from: data)
    }
}
