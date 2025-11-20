import Foundation
import PackageManifestKit

/// Represents the complete dependency graph of a package and its dependencies.
package struct ModulesGraph: Sendable {
    /// The root package that composes the ModulesGraph.
    package var rootPackage: ResolvedPackage

    /// Dictionary of all packages in the dependency graph, keyed by their unique package ID.
    package var allPackages: [PackageID: ResolvedPackage]

    /// Set of all modules across all packages in the dependency graph.
    package var allModules: Set<ResolvedModule>

    /// Returns the package that contains the specified module.
    ///
    /// - Parameter module: The module to look up.
    /// - Returns: The package containing the module, or `nil` if not found.
    package func package(for module: ResolvedModule) -> ResolvedPackage? {
        allPackages[module.packageID]
    }

    package init(rootPackage: ResolvedPackage, allPackages: [PackageID: ResolvedPackage], allModules: Set<ResolvedModule>) {
        self.rootPackage = rootPackage
        self.allPackages = allPackages
        self.allModules = allModules
    }
}

/// A unique identifier for a Swift package within the dependency graph.
public struct PackageID: Hashable, Codable, Sendable {
    /// A description of the package, typically its URL or registry identifier.
    public var description: String

    /// The unique identity string of the package.
    public var packageIdentity: String

    package init(
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

/// A fully resolved package. Contains resolved modules, products and dependencies of the package.
public struct ResolvedPackage: Identifiable, Codable, Sendable {
    /// Unique identifier for the package.
    public var id: PackageID

    /// The package's manifest.
    public var manifest: Manifest

    /// The actual resolved kind of the package (may differ from manifest's package kind).
    public var resolvedPackageKind: PackageKind

    /// File system path to the package directory.
    public var path: String

    /// All resolved modules defined in this package.
    public var targets: [ResolvedModule]

    /// All products defined in this package.
    public var products: [ResolvedProduct]

    /// The pinned state of the package from Package.resolved, if available.
    public var pinState: Pin.State?

    /// The name of the package.
    public var name: String {
        manifest.name
    }

    package init(
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

/// Represents a fully resolved module. All the dependencies for this module are also stored as resolved.
public struct ResolvedModule: Hashable, Sendable, Codable {
    /// Represents dependency of a resolved module.
    public enum Dependency: Hashable, Codable, Sendable {
        /// Direct dependency of the module.
        case module(ResolvedModule, conditions: [PackageCondition])

        /// The module depends on this product.
        case product(ResolvedProduct, conditions: [PackageCondition])
    }

    /// The underlying target from the package manifest.
    public var underlying: PackageManifestKit.Target

    /// All resolved dependencies of this module (both modules and products).
    public var dependencies: [Dependency]

    /// URL to the local package directory containing this module.
    public var localPackageURL: URL

    /// Identifier of the package that contains this module.
    public var packageID: PackageID

    /// The resolved type of this module (Swift, Clang, or binary).
    public var resolvedModuleType: ResolvedModuleType

    package init(
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

/// Represents a fully resolved product.
public struct ResolvedProduct: Hashable, Codable, Sendable {
    /// The underlying product from the package manifest.
    public var underlying: PackageManifestKit.Product

    /// All modules (targets) that compose this product.
    public var modules: [ResolvedModule]

    /// The type of product.
    public var type: ProductType

    /// Identifier of the package that contains this product.
    public var packageID: PackageID

    /// The name of the product, derived from its manifest.
    public var name: String {
        underlying.name
    }

    package init(
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

/// Represents the type of a resolved module.
///
/// Swift packages can contain different types of modules.
/// This enum captures the module type along with any type-specific information needed for building.
public enum ResolvedModuleType: Hashable, Codable, Sendable {
    /// A Clang (C/C++/Objective-C) module with include directory and public headers.
    case clang(includeDir: URL, publicHeaders: [URL])

    /// A pre-built binary framework (XCFramework).
    case binary(BinaryArtifactLocation)

    /// A Swift module (compiled from Swift source).
    case swift

    /// Returns the include directory for Clang modules, or `nil` for other module types.
    public var includeDir: URL? {
        switch self {
        case .clang(let includeDir, _):
            includeDir
        default: nil
        }
    }

    /// Specifies the location of a binary artifact (XCFramework).
    public enum BinaryArtifactLocation: Hashable, Codable, Sendable {
        case local(URL)
        case remote(packageIdentity: String, name: String)

        /// Returns the URL to the artifact file.
        ///
        /// - Parameter rootPackageDirectory: The root package directory.
        /// - Returns: URL to the artifact's XCFramework file.
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

/// Represents the contents of a Package.resolved file.
public struct PackageResolved: Decodable, Sendable {
    public let originHash: String?
    public let pins: [Pin]
    public let version: Int
}

/// Represents a pinned package version in Package.resolved.
public struct Pin: Sendable, Codable, Identifiable, Hashable {
    /// Unique identifier for the pin (same as identity).
    public var id: String {
        identity
    }

    /// Unique identity string of the package.
    public var identity: String

    /// Kind of package.
    public var kind: String

    /// Location of the package.
    public var location: String

    /// The pinned state (revision, version, or branch).
    public var state: State

    /// Represents the exact state of a pinned package.
    ///
    /// The state contains the revision and optionally either a semantic version
    /// or a branch name, depending on how the package was pinned.
    public struct State: Sendable, Codable, Hashable {
        /// Git commit revision (SHA) of the pinned package.
        public var revision: String

        /// Semantic version string.
        public var version: String?

        /// Branch name.
        public var branch: String?

        package init(revision: String, version: String? = nil, branch: String? = nil) {
            self.revision = revision
            self.version = version
            self.branch = branch
        }
    }
}

/// Represents metadata about a dependency package from `swift package show-dependencies`.
public struct DependencyPackage: Decodable, Identifiable, Hashable, Sendable {
    /// Unique identifier (same as identity).
    public var id: String {
        identity
    }

    /// Unique identity string of the package.
    public var identity: String

    /// Display name of the package.
    public var name: String

    /// URL or location string of the package.
    public var url: String

    /// Version string of the resolved package.
    public var version: String

    /// Local file system path where the package is checked out.
    public var path: String

    package init(identity: String, name: String, url: String, version: String, path: String) {
        self.identity = identity
        self.name = name
        self.url = url
        self.version = version
        self.path = path
    }
}
