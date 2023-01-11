import Foundation
import PackageModel
import PackageGraph
import TSCBasic

struct BuildFlagsGenerator {
    private let package: Package
    private let target: ResolvedTarget
    private let buildConfiguration: BuildConfiguration
    private let platforms: Set<SDK>

    enum Error: LocalizedError {
        case unsupportedSettings(TargetBuildSettingDescription.Setting)

        var errorDescription: String? {
            switch self {
            case .unsupportedSettings(let setting):
                return "Unsupported settings \(setting.kind) for \(setting.tool)"
            }
        }
    }

    init(package: Package, target: ResolvedTarget, buildConfiguration: BuildConfiguration, platforms: Set<SDK>) {
        self.package = package
        self.target = target
        self.buildConfiguration = buildConfiguration
        self.platforms = platforms
    }

    func generate() throws -> [String: XCConfigValue] {
        guard let targetDescription = package.manifest.targets.first(where: { $0.name == target.name }) else {
            return [:]
        }
        return try targetDescription.settings
            .filter { setting in
                if let condition = setting.condition {
                    return self.satisfyConditions(condition)
                } else {
                    return true
                }
            }
            .reduce(into: [:]) { settings, setting in
                settings.merge(try xcodeprojSettings(for: setting))
            }
    }

    private func xcodeprojSettings(for setting: TargetBuildSettingDescription.Setting) throws -> [String: XCConfigValue] {
        switch setting.tool {
        case .c:
            return try cSettings(for: setting)
        case .cxx:
            return try cxxSettings(for: setting)
        case .swift:
            return try swiftSettings(for: setting)
        case .linker:
            return try linkerSettings(for: setting)
        }
    }


    private func satisfyConditions(_ condition: PackageConditionDescription) -> Bool {
        Set(condition.platformNames).isSuperset(of: platforms.map(\.rawValue)) && condition.config == buildConfiguration.settingsValue
    }

    private func resolvePath(for value: String) throws -> String {
        let targetRoot = target.underlyingTarget.path
        let subPath = try RelativePath(validating: value)
        return targetRoot.appending(subPath).pathString
    }

    private func cSettings(for setting: TargetBuildSettingDescription.Setting) throws -> [String: XCConfigValue] {
        precondition(setting.tool == .c, "invalid tool")
        switch setting.kind {
        case .headerSearchPath(let value):
            return ["HEADER_SEARCH_PATHS": .string(try resolvePath(for: value))]
        case .define(let value):
            return ["GCC_PREPROCESSOR_DEFINITIONS": .string(value)]
        case .linkedFramework:
            throw Error.unsupportedSettings(setting)
        case .linkedLibrary:
            throw Error.unsupportedSettings(setting)
        case .unsafeFlags(let value):
            return ["OTHER_CFLAGS": .list(value)]
        }
    }

    private func cxxSettings(for setting: TargetBuildSettingDescription.Setting) throws -> [String: XCConfigValue] {
        precondition(setting.tool == .cxx, "invalid tool")
        switch setting.kind {
        case .headerSearchPath(let value):
            return ["HEADER_SEARCH_PATHS": .string(try resolvePath(for: value))]
        case .define(let value):
            return ["GCC_PREPROCESSOR_DEFINITIONS": .string(value)]
        case .linkedFramework:
            throw Error.unsupportedSettings(setting)
        case .linkedLibrary:
            throw Error.unsupportedSettings(setting)
        case .unsafeFlags(let value):
            return ["OTHER_CPLUSPLUSFLAGS": .list(value)]
        }
    }

    private func swiftSettings(for setting: TargetBuildSettingDescription.Setting) throws -> [String: XCConfigValue] {
        precondition(setting.tool == .swift, "invalid tool")
        switch setting.kind {
        case .headerSearchPath:
            throw Error.unsupportedSettings(setting)
        case .define(let value):
            return ["SWIFT_ACTIVE_COMPILATION_CONDITIONS": .string(value)]
        case .linkedFramework:
            throw Error.unsupportedSettings(setting)
        case .linkedLibrary:
            throw Error.unsupportedSettings(setting)
        case .unsafeFlags(let value):
            return ["OTHER_SWIFT_FLAGS": .list(value)]
        }
    }

    private func linkerSettings(for setting: TargetBuildSettingDescription.Setting) throws -> [String: XCConfigValue] {
        precondition(setting.tool == .linker, "invalid tool")
        switch setting.kind {
        case .headerSearchPath:
            throw Error.unsupportedSettings(setting)
        case .define:
            throw Error.unsupportedSettings(setting)
        case .linkedFramework(let value):
            return ["LINK_LIBRARIES": .string(value)]
        case .linkedLibrary(let value):
            return ["LINK_FRAMEWORKS": .string(value)]
        case .unsafeFlags(let value):
            return ["OTHER_LDFLAGS": .list(value)]
        }
    }
}
