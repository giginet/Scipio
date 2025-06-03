import Foundation
import PackageManifestKit

typealias Pins = [PackageID: Pin.State]

struct ModulesGraph {
    var rootPackage: ResolvedPackage
    var allPackages: [PackageID: ResolvedPackage]
    var allModules: Set<ResolvedModule>

    func package(for module: ResolvedModule) -> ResolvedPackage? {
        allPackages[module.packageID]
    }

    func module(for name: String) -> ResolvedModule? {
        allModules.first { $0.name == name }
    }
}

struct PackageID: Hashable {
    var description: String
    var packageIdentity: String

    init(
        packageKind: PackageKind,
        packageIdentity: String
    ) {
        // FIXME: Dependency mirroring is not considered here yet.
        // If a package is resolved using the original URL in one case and a mirror URL in another,
        // the cache key may not match correctly, which could cause cache restore to fail.
        self.packageIdentity = packageIdentity
        switch packageKind {
        case .root(let url), .fileSystem(let url), .localSourceControl(let url):
            description = url.absoluteString
        case .remoteSourceControl(let string):
            description = string
        case .registry(let string):
            description = string
        }
    }
}

struct ResolvedPackage: Identifiable {
    var id: PackageID
    var manifest: Manifest
    var resolvedPackageKind: PackageKind
    var path: String
    var targets: [ResolvedModule]
    var products: [ResolvedProduct]
    var pinState: Pin.State?

    var name: String {
        manifest.name
    }

    init(
        manifest: Manifest,
        resolvedPackageKind: PackageKind,
        packageIdentity: String,
        pinState: Pin.State?,
        path: String,
        targets: [ResolvedModule],
        products: [ResolvedProduct]
    ) {
        self.id = ID(packageKind: manifest.packageKind, packageIdentity: packageIdentity)
        self.manifest = manifest
        self.resolvedPackageKind = resolvedPackageKind
        self.pinState = pinState
        self.path = path
        self.targets = targets
        self.products = products
    }
}

extension ResolvedPackage {
    var canonicalPackageLocation: CanonicalPackageLocation {
        CanonicalPackageLocation(
            URL(filePath: path)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path(percentEncoded: false)
        )
    }
}

struct ResolvedModule: Hashable, Sendable {
    enum Dependency: Hashable, Identifiable {
        var id: String {
            switch self {
            case .module(let module, _):
                module.name
            case .product(let product, _):
                product.name + product.modules.map(\.name).joined()
            }
        }

        case module(ResolvedModule, conditions: [PackageCondition])
        case product(ResolvedProduct, conditions: [PackageCondition])

        var dependencies: [Dependency] {
            switch self {
            case .module(let module, _):
                return module.dependencies
            case .product(let product, _):
                return product.modules.map { .module($0, conditions: []) }
            }
        }

        var module: ResolvedModule? {
            switch self {
            case .module(let module, _): return module
            case .product: return nil
            }
        }

        var product: ResolvedProduct? {
            switch self {
            case .module: return nil
            case .product(let product, _): return product
            }
        }

        var moduleNames: [String] {
            let moduleNames = switch self {
            case .module(let module, _): [module.name]
            case .product(let product, _): product.modules.map(\.name)
            }
            return moduleNames
        }
    }

    var underlying: PackageManifestKit.Target
    var dependencies: [Dependency]
    var localPackageURL: URL
    var packageID: PackageID
    var resolvedModuleType: ResolvedModuleType

    var name: String {
        underlying.name
    }

    var c99name: String {
        name.spm_mangledToC99ExtendedIdentifier()
    }

    var xcFrameworkName: String {
        "\(c99name.packageNamed()).xcframework"
    }

    var modulemapName: String {
        "\(c99name.packageNamed()).modulemap"
    }

    func recursiveModuleDependencies() throws -> [ResolvedModule] {
        try topologicalSort(self.dependencies) { $0.dependencies }.compactMap { $0.module }
    }

    func recursiveDependencies() throws -> [Dependency] {
        try topologicalSort(self.dependencies) { $0.dependencies }
    }
}

struct ResolvedProduct: Hashable {
    var underlying: PackageManifestKit.Product
    var modules: [ResolvedModule]
    var type: ProductType
    var packageID: PackageID

    var name: String {
        underlying.name
    }
}

enum ResolvedModuleType: Hashable {
    case clang(includeDir: URL, publicHeaders: [URL])
    case binary(BinaryArtifactLocation)
    case swift

    var includeDir: URL? {
        switch self {
        case .clang(let includeDir, _):
            includeDir
        default: nil
        }
    }

    enum BinaryArtifactLocation: Hashable {
        case local(URL)
        case remote(packageIdentity: String, name: String)

        func artifactURL(rootPackageDirectory: URL) -> URL {
            switch self {
            case .local(let url):
                return url
            case .remote(let packageIdentity, let name):
                return rootPackageDirectory
                    .appending(components: ".build", "artifacts", packageIdentity, name, name)
                    .appendingPathExtension("xcframework")
            }
        }
    }
}

struct PackageResolved: Decodable {
    let pins: [Pin]
    let version: Int
}

struct Pin: Sendable, Codable, Identifiable, Hashable {
    var id: String {
        identity
    }

    var identity: String
    var kind: String
    var location: String
    var state: State

    struct State: Sendable, Codable, Hashable {
        var revision: String
        var version: String?
        var branch: String?
    }
}

struct DependencyPackage: Decodable, Identifiable, Hashable {
    var id: String {
        identity
    }

    var identity: String
    var name: String
    var url: String
    var version: String
    var path: String
}
