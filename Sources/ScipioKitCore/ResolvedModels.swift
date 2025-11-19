import Foundation
import PackageManifestKit

public struct ModulesGraph: Sendable {
    public var rootPackage: ResolvedPackage
    public var allPackages: [PackageID: ResolvedPackage]
    public var allModules: Set<ResolvedModule>

    public func package(for module: ResolvedModule) -> ResolvedPackage? {
        allPackages[module.packageID]
    }

    public init(rootPackage: ResolvedPackage, allPackages: [PackageID: ResolvedPackage], allModules: Set<ResolvedModule>) {
        self.rootPackage = rootPackage
        self.allPackages = allPackages
        self.allModules = allModules
    }
}

public struct PackageID: Hashable, Codable, Sendable {
    public var description: String
    public var packageIdentity: String

    public init(
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

public struct ResolvedPackage: Identifiable, Codable, Sendable {
    public var id: PackageID
    public var manifest: Manifest
    public var resolvedPackageKind: PackageKind
    public var path: String
    public var targets: [ResolvedModule]
    public var products: [ResolvedProduct]
    public var pinState: Pin.State?

    public var name: String {
        manifest.name
    }

    public init(
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

public struct ResolvedModule: Hashable, Sendable, Codable {
    public enum Dependency: Hashable, Codable, Sendable {
        case module(ResolvedModule, conditions: [PackageCondition])
        case product(ResolvedProduct, conditions: [PackageCondition])
    }

    public var underlying: PackageManifestKit.Target
    public var dependencies: [Dependency]
    public var localPackageURL: URL
    public var packageID: PackageID
    public var resolvedModuleType: ResolvedModuleType

    public init(
        underlying: PackageManifestKit.Target,
        dependencies: [Dependency],
        localPackageURL: URL,
        packageID: PackageID,
        resolvedModuleType: ResolvedModuleType
    ) {
        self.underlying = underlying
        self.dependencies = dependencies
        self.localPackageURL = localPackageURL
        self.packageID = packageID
        self.resolvedModuleType = resolvedModuleType
    }
}

public struct ResolvedProduct: Hashable, Codable, Sendable {
    public var underlying: PackageManifestKit.Product
    public var modules: [ResolvedModule]
    public var type: ProductType
    public var packageID: PackageID

    public var name: String {
        underlying.name
    }

    public init(
        underlying: PackageManifestKit.Product,
        modules: [ResolvedModule],
        type: ProductType,
        packageID: PackageID
    ) {
        self.underlying = underlying
        self.modules = modules
        self.type = type
        self.packageID = packageID
    }
}

public enum ResolvedModuleType: Hashable, Codable, Sendable {
    case clang(includeDir: URL, publicHeaders: [URL])
    case binary(BinaryArtifactLocation)
    case swift

    public var includeDir: URL? {
        switch self {
        case .clang(let includeDir, _):
            includeDir
        default: nil
        }
    }

    public enum BinaryArtifactLocation: Hashable, Codable, Sendable {
        case local(URL)
        case remote(packageIdentity: String, name: String)

        public func artifactURL(rootPackageDirectory: URL) -> URL {
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

public struct PackageResolved: Decodable, Sendable {
    public let originHash: String?
    public let pins: [Pin]
    public let version: Int
}

public struct Pin: Sendable, Codable, Identifiable, Hashable {
    public var id: String {
        identity
    }

    public var identity: String
    public var kind: String
    public var location: String
    public var state: State

    public struct State: Sendable, Codable, Hashable {
        public var revision: String
        public var version: String?
        public var branch: String?

        public init(revision: String, version: String? = nil, branch: String? = nil) {
            self.revision = revision
            self.version = version
            self.branch = branch
        }
    }
}

public struct DependencyPackage: Decodable, Identifiable, Hashable, Sendable {
    public var id: String {
        identity
    }

    public var identity: String
    public var name: String
    public var url: String
    public var version: String
    public var path: String

    public init(identity: String, name: String, url: String, version: String, path: String) {
        self.identity = identity
        self.name = name
        self.url = url
        self.version = version
        self.path = path
    }
}
