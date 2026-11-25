import Foundation
import enum PIFKit.PIFDependency
import ScipioKitCore

struct MacroBuildPlan {
    let modules: [ResolvedModule]
    let targetDependencies: [String: [String]]
    let hostOnlyDependencies: [String: Set<PIFDependency>]
    let hostOnlyProductDependencies: [String: Set<PIFDependency>]

    init(
        graph: DependencyGraph<BuildProduct>, buildOptions: BuildOptions,
        buildOptionsMatrix: [String: BuildOptions] = [:]
    ) throws {
        let dependencies = try graph.allNodes.reduce(into: (
            plugins: [String: ResolvedModule](),
            targets: [String: [String]](),
            hostOnly: [String: Set<PIFDependency>]()
        )) { dependencies, node in
            let target = node.value.target
            let options = buildOptionsMatrix[target.name] ?? buildOptions
            let macroDependencies = Self.macroDependencies(for: target)
            let macros = options.sdks.flatMap { sdk in
                Self.macroDependencies(for: target, sdk: sdk, configuration: options.buildConfiguration)
                    .flatMap(\.modules).filter { $0.underlying.type == .macro }
            }
            for macro in macros {
                if let existing = dependencies.plugins[macro.c99name],
                   existing.packageID != macro.packageID || existing.name != macro.name {
                    throw Error.duplicateModule(macro.c99name)
                }
                dependencies.plugins[macro.c99name] = macro
            }
            if !macros.isEmpty {
                dependencies.targets[target.name] = Set(macros.map(\.c99name)).sorted()
            }
            if !macroDependencies.isEmpty {
                dependencies.hostOnly[target.name] = Self.hostOnlyDependencyReferences(
                    for: [target], buildOptions: options
                )
            }
        }
        self.modules = dependencies.plugins.values.sorted { $0.c99name < $1.c99name }
        self.targetDependencies = dependencies.targets
        self.hostOnlyDependencies = dependencies.hostOnly
        let packages = Dictionary(graph.allNodes.map { ($0.value.package.id, $0.value.package) }, uniquingKeysWith: { first, _ in first })
        self.hostOnlyProductDependencies = packages.values.flatMap(\.products).reduce(into: [:]) { result, product in
            guard product.modules.contains(where: { dependencies.hostOnly[$0.name] != nil }) else { return }
            result[product.name] = Self.hostOnlyDependencyReferences(
                for: product.modules, buildOptions: buildOptions, buildOptionsMatrix: buildOptionsMatrix
            )
        }
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

    private static func hostOnlyDependencyReferences(
        for targets: [ResolvedModule], buildOptions: BuildOptions, buildOptionsMatrix: [String: BuildOptions] = [:]
    ) -> Set<PIFDependency> {
        // dump-pif retains inactive macro edges; they must also be removed from destination builds.
        let hostReferences = dependencyReferences(for: targets.flatMap { macroDependencies(for: $0) })
        let runtimeReferences = targets.reduce(into: Set(targets.map { PIFDependency.target($0.name) })) { references, target in
            let options = buildOptionsMatrix[target.name] ?? buildOptions
            for sdk in options.sdks {
                references.formUnion(dependencyReferences(
                    for: target.dependencies, sdk: sdk, configuration: options.buildConfiguration, excluding: [target]
                ))
            }
        }
        return hostReferences.subtracting(runtimeReferences)
    }

    private static func dependencyReferences(
        for dependencies: [ResolvedModule.Dependency], sdk: SDK? = nil, configuration: BuildConfiguration = .debug,
        excluding modules: Set<ResolvedModule> = []
    ) -> Set<PIFDependency> {
        var visited = modules
        func collect(_ dependency: ResolvedModule.Dependency, into references: inout Set<PIFDependency>) {
            if let sdk, !isEnabled(dependency, sdk: sdk, configuration: configuration) { return }
            let modules = dependency.modules.filter { sdk == nil || $0.underlying.type != .macro }
            guard !modules.isEmpty else { return }
            if let product = dependency.product {
                references.insert(.product(product.name))
            }
            for module in modules where visited.insert(module).inserted {
                references.insert(.target(module.name))
                for child in module.dependencies {
                    collect(child, into: &references)
                }
            }
        }
        return dependencies.reduce(into: []) { references, dependency in
            collect(dependency, into: &references)
        }
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
