import Foundation
import ScipioKitCore

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

extension ResolvedModule {
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

    /// The dependencies to link as frameworks. The walk mirrors the build-product
    /// pruning: modules reachable only through non-producible targets build no
    /// framework, and system-library modules are packaged but resolve through the SDK.
    func recursiveFrameworkLinkableDependencies() -> [Dependency] {
        var visitedModuleNames = Set<String>()
        var linkable: [Dependency] = []

        func visit(_ dependencies: [Dependency]) {
            for dependency in dependencies {
                switch dependency {
                case .product:
                    visit(dependency.dependencies)
                case .module(let module, _):
                    guard visitedModuleNames.insert(module.name).inserted else { continue }
                    guard module.underlying.type.isFrameworkProducible else { continue }
                    if module.underlying.type.isFrameworkLinkable {
                        linkable.append(dependency)
                    }
                    visit(module.dependencies)
                }
            }
        }

        visit(dependencies)
        return linkable
    }
}

extension ResolvedModule.Dependency {
    var dependencies: [Self] {
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

    var modules: [ResolvedModule] {
        switch self {
        case .module(let module, _): [module]
        case .product(let product, _): product.modules
        }
    }

    var moduleNames: [String] {
        modules.map(\.name)
    }
}

extension ResolvedModule.Dependency: Identifiable {
    public var id: String {
        switch self {
        case .module(let module, _):
            module.name
        case .product(let product, _):
            product.name + product.modules.map(\.name).joined()
        }
    }
}

extension ModulesGraph {
    func module(for name: String) -> ResolvedModule? {
        allModules.first { $0.name == name }
    }
}
