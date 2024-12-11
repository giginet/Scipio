import Basics
import TSCBasic
import PackageModel

/// Holds the packageDirectory Scipio works on, and defines some path-related functionalities.
protocol PackageLocator {
    var packageDirectory: TSCAbsolutePath { get }
}

extension PackageLocator {
    var buildDirectory: TSCAbsolutePath {
        packageDirectory.appending(component: ".build")
    }

    var workspaceDirectory: TSCAbsolutePath {
        buildDirectory.appending(component: "scipio")
    }

    var derivedDataPath: TSCAbsolutePath {
        workspaceDirectory.appending(component: "DerivedData")
    }

    func generatedModuleMapPath(of target: ScipioResolvedModule, sdk: SDK) throws -> TSCAbsolutePath {
        let relativePath = try TSCBasic.RelativePath(validating: "ModuleMapsForFramework/\(sdk.settingValue)")
        return workspaceDirectory
            .appending(relativePath)
            .appending(component: target.modulemapName)
    }

    /// Returns an Products directory path
    /// It should be the default setting of `TARGET_BUILD_DIR`
    func productsDirectory(buildConfiguration: BuildConfiguration, sdk: SDK) -> TSCAbsolutePath {
        let intermediateDirectoryName = productDirectoryName(
            buildConfiguration: buildConfiguration,
            sdk: sdk
        )
        return derivedDataPath.appending(components: ["Products", intermediateDirectoryName])
    }

    /// Returns a directory path which contains assembled frameworks
    var assembledFrameworksRootDirectory: TSCAbsolutePath {
        workspaceDirectory.appending(component: "AssembledFrameworks")
    }

    /// Returns a directory path of the assembled frameworks path for the specific Configuration/Platform
    func assembledFrameworksDirectory(buildConfiguration: BuildConfiguration, sdk: SDK) -> TSCAbsolutePath {
        let intermediateDirName = productDirectoryName(buildConfiguration: buildConfiguration, sdk: sdk)
        return assembledFrameworksRootDirectory
            .appending(component: intermediateDirName)
    }

    /// Returns an intermediate directory name in the Products dir.
    /// e.g. `Debug` / `Debug-iphoneos`
    private func productDirectoryName(buildConfiguration: BuildConfiguration, sdk: SDK) -> String {
        if sdk == .macOS {
            return buildConfiguration.settingsValue
        } else {
            return "\(buildConfiguration.settingsValue)-\(sdk.settingValue)"
        }
    }
}
