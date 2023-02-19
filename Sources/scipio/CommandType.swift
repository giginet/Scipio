import Foundation
import ScipioKit

enum CommandType {
    case create(platformSpecifier: Runner.Options.PlatformSpecifier)
    case prepare(cacheMode: Runner.Options.CacheMode)

    var mode: Runner.Mode {
        switch self {
        case .create:
            return .createPackage
        case .prepare:
            return .prepareDependencies
        }
    }

    var platformSpecifier: Runner.Options.PlatformSpecifier {
        switch self {
        case .create(let platform):
            return platform
        case .prepare:
            return .manifest
        }
    }

    var cacheMode: Runner.Options.CacheMode {
        switch self {
        case .create:
            return .disabled
        case .prepare(let cacheMode):
            return cacheMode
        }
    }
}

extension Runner {
    init(commandType: CommandType, buildOptions: BuildOptionGroup, globalOptions: GlobalOptionGroup) {
        let baseBuildOptions = Runner.Options.BuildOptions(
            buildConfiguration: buildOptions.buildConfiguration,
            platforms: commandType.platformSpecifier,
            isSimulatorSupported: buildOptions.supportSimulators,
            isDebugSymbolsEmbedded: buildOptions.embedDebugSymbols,
            frameworkType: buildOptions.frameworkType
        )
        let runnerOptions = Runner.Options(
            baseBuildOptions: baseBuildOptions,
            cacheMode: Self.cacheMode(from: commandType),
            overwrite: buildOptions.overwrite,
            verbose: globalOptions.verbose
        )
        self.init(mode: commandType.mode, options: runnerOptions)
    }

    private static func cacheMode(from commandType: CommandType) -> Runner.Options.CacheMode {
        switch commandType {
        case .create:
            return .disabled
        case .prepare(let cacheMode):
            return cacheMode
        }
    }

}
