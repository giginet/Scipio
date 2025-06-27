import TSCBasic
import Foundation

/// Holds the packageDirectory Scipio works on, and defines some path-related functionalities.
protocol PackageLocator: Sendable {
    var packageDirectory: URL { get }
}

extension PackageLocator {
    var buildDirectory: URL {
        packageDirectory.appending(component: ".build")
    }

    var workspaceDirectory: URL {
        buildDirectory.appending(component: "scipio")
    }

    var derivedDataPath: URL {
        workspaceDirectory.appending(component: "DerivedData")
    }

    func generatedModuleMapPath(of target: ResolvedModule, sdk: SDK) throws -> URL {
        workspaceDirectory
            .appending(components: "ModuleMapsForFramework", sdk.settingValue, target.modulemapName)
    }

    /// Returns an Products directory path
    /// It should be the default setting of `TARGET_BUILD_DIR`
    func productsDirectory(buildConfiguration: BuildConfiguration, sdk: SDK) -> URL {
        let intermediateDirectoryName = productDirectoryName(
            buildConfiguration: buildConfiguration,
            sdk: sdk
        )
        return derivedDataPath.appending(components: "Products", intermediateDirectoryName)
    }

    /// Returns a directory path which contains assembled frameworks
    var assembledFrameworksRootDirectory: URL {
        workspaceDirectory.appending(component: "AssembledFrameworks")
    }

    /// Returns a directory path of the assembled frameworks path for the specific Configuration/Platform
    func assembledFrameworksDirectory(buildConfiguration: BuildConfiguration, sdk: SDK) -> URL {
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
