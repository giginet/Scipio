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

    var moduleNames: [String] {
        let moduleNames = switch self {
        case .module(let module, _): [module.name]
        case .product(let product, _): product.modules.map(\.name)
        }
        return moduleNames
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
