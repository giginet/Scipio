import Foundation
import ScipioKit

enum CommandType {
    case create(platformSpecifier: Runner.Options.PlatformSpecifier)
    case prepare(cachePolicies: [Runner.Options.CachePolicy])

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

    var cachePolicies: [Runner.Options.CachePolicy] {
        switch self {
        case .create:
            return []
        case .prepare(let cachePolicies):
            return cachePolicies
        }
    }
}

extension Runner {
    init(commandType: CommandType, buildOptions: BuildOptionGroup, globalOptions: GlobalOptionGroup) {
        // FIXME it's strange to raise the error here, but it will be removed in a future release
        if buildOptions.shouldBuildStaticFramework {
            fatalError("--static is deprecated. Use `-framework-type static` instead.")
        }

        let baseBuildOptions = Runner.Options.BuildOptions(
            buildConfiguration: buildOptions.buildConfiguration,
            platforms: commandType.platformSpecifier,
            isSimulatorSupported: buildOptions.supportSimulators,
            isDebugSymbolsEmbedded: buildOptions.embedDebugSymbols,
            frameworkType: buildOptions.frameworkType,
            enableLibraryEvolution: buildOptions.shouldEnableLibraryEvolution
        )
        let runnerOptions = Runner.Options(
            baseBuildOptions: baseBuildOptions,
            shouldOnlyUseVersionsFromResolvedFile: buildOptions.shouldOnlyUseVersionsFromResolvedFile,
            cachePolicies: Self.cachePolicies(from: commandType),
            overwrite: buildOptions.overwrite,
            verbose: globalOptions.verbose
        )
        self.init(mode: commandType.mode, options: runnerOptions)
    }

    private static func cachePolicies(from commandType: CommandType) -> [Runner.Options.CachePolicy] {
        switch commandType {
        case .create:
            return []
        case .prepare(let cachePolicies):
            return cachePolicies
        }
    }

}
