import Foundation
import ScipioKitCore

struct MacroBuildPlan {
    let modules: [ResolvedModule]
    let targetDependencies: [String: [String]]
    let hostOnlyDependencies: [String: Set<String>]
    let hostOnlyProductDependencies: [String: Set<String>]

    init(
        graph: DependencyGraph<BuildProduct>, buildOptions: BuildOptions,
        buildOptionsMatrix: [String: BuildOptions] = [:]
    ) throws {
        var plugins: [String: ResolvedModule] = [:]
        var targetDependencies: [String: [String]] = [:]
        var hostOnlyDependencies: [String: Set<String>] = [:]
        for node in graph.allNodes {
            let target = node.value.target
            let options = buildOptionsMatrix[target.name] ?? buildOptions
            let macroDependencies = Self.macroDependencies(for: target)
            let macros = options.sdks.flatMap { sdk in
                Self.macroDependencies(for: target, sdk: sdk, configuration: options.buildConfiguration)
                    .flatMap(\.modules).filter { $0.underlying.type == .macro }
            }
            for macro in macros {
                if let existing = plugins[macro.c99name],
                   existing.packageID != macro.packageID || existing.name != macro.name {
                    throw Error.duplicateModule(macro.c99name)
                }
                plugins[macro.c99name] = macro
            }
            if !macros.isEmpty {
                targetDependencies[target.name] = Set(macros.map(\.c99name)).sorted()
            }
            if !macroDependencies.isEmpty {
                hostOnlyDependencies[target.name] = Self.hostOnlyDependencyNames(
                    for: [target], buildOptions: options
                )
            }
        }
        self.modules = plugins.values.sorted { $0.c99name < $1.c99name }
        self.targetDependencies = targetDependencies
        self.hostOnlyDependencies = hostOnlyDependencies
        var productDependencies: [String: Set<String>] = [:]
        let packages = Dictionary(graph.allNodes.map { ($0.value.package.id, $0.value.package) }, uniquingKeysWith: { first, _ in first })
        for package in packages.values {
            for product in package.products where product.modules.contains(where: { hostOnlyDependencies[$0.name] != nil }) {
                productDependencies[product.name] = Self.hostOnlyDependencyNames(
                    for: product.modules, buildOptions: buildOptions, buildOptionsMatrix: buildOptionsMatrix
                )
            }
        }
        self.hostOnlyProductDependencies = productDependencies
    }

    private static func macroDependencies(
        for target: ResolvedModule, sdk: SDK? = nil, configuration: BuildConfiguration = .debug
    ) -> [ResolvedModule.Dependency] {
        var pending = target.dependencies
        var index = 0
        var visited: Set<ResolvedModule> = [target]
        var macros: [ResolvedModule.Dependency] = []
        while index < pending.count {
            let dependency = pending[index]
            index += 1
            if let sdk, !isEnabled(dependency, sdk: sdk, configuration: configuration) { continue }
            if dependency.modules.contains(where: { $0.underlying.type == .macro }) {
                macros.append(dependency)
            }
            for module in dependency.modules where module.underlying.type != .macro && visited.insert(module).inserted {
                pending.append(contentsOf: module.dependencies)
            }
        }
        return macros
    }

    private static func hostOnlyDependencyNames(
        for targets: [ResolvedModule], buildOptions: BuildOptions, buildOptionsMatrix: [String: BuildOptions] = [:]
    ) -> Set<String> {
        var hostNames: Set<String> = []
        var runtimeNames: Set<String> = []
        var hostVisited: Set<ResolvedModule> = []

        func collect(
            _ dependencies: [ResolvedModule.Dependency], sdk: SDK? = nil, configuration: BuildConfiguration = .debug,
            names: inout Set<String>, visited: inout Set<ResolvedModule>
        ) {
            for dependency in dependencies {
                if let sdk, !isEnabled(dependency, sdk: sdk, configuration: configuration) { continue }
                let modules = dependency.modules.filter { sdk == nil || $0.underlying.type != .macro }
                guard !modules.isEmpty else { continue }
                if let product = dependency.product {
                    names.insert(product.name)
                }
                for module in modules where visited.insert(module).inserted {
                    names.insert(module.name)
                    collect(module.dependencies, sdk: sdk, configuration: configuration, names: &names, visited: &visited)
                }
            }
        }
        // dump-pif retains inactive macro edges; they must also be removed from destination builds.
        for target in targets {
            collect(macroDependencies(for: target), names: &hostNames, visited: &hostVisited)
            runtimeNames.insert(target.name)
            let options = buildOptionsMatrix[target.name] ?? buildOptions
            for sdk in options.sdks {
                var runtimeVisited: Set<ResolvedModule> = [target]
                collect(target.dependencies, sdk: sdk, configuration: options.buildConfiguration, names: &runtimeNames, visited: &runtimeVisited)
            }
        }
        return hostNames.subtracting(runtimeNames)
    }

    private static func isEnabled(_ dependency: ResolvedModule.Dependency, sdk: SDK, configuration: BuildConfiguration) -> Bool {
        let conditions = switch dependency {
        case .module(_, let conditions), .product(_, let conditions): conditions
        }
        return conditions.allSatisfy { condition in
            let matchesPlatform = condition.platformNames.isEmpty || condition.platformNames.contains(platformName(for: sdk))
            return matchesPlatform && (condition.config == nil || condition.config == configuration.rawValue)
        }
    }

    private static func platformName(for sdk: SDK) -> String {
        switch sdk {
        case .macOS: "macos"
        case .macCatalyst: "maccatalyst"
        case .iOS, .iOSSimulator: "ios"
        case .tvOS, .tvOSSimulator: "tvos"
        case .watchOS, .watchOSSimulator: "watchos"
        case .visionOS, .visionOSSimulator: "visionos"
        }
    }

    enum Error: LocalizedError {
        case duplicateModule(String)

        var errorDescription: String? {
            switch self {
            case .duplicateModule(let name): "Multiple macro targets use the module name \(name)."
            }
        }
    }
}
