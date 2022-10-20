import TSCBasic
import PackageGraph

struct ArchiveCommand: XcodeBuildCommand {

    let subCommand = "archive"

    var package: Package
    var target: ResolvedTarget
    var buildConfiguration: BuildConfiguration
    var sdk: SDK

    var options: [XcodeBuildOption] {
        [
            ("project", projectPath.pathString),
            ("configuration", buildConfiguration.settingsValue),
            ("scheme", target.name),
            ("archivePath", xcArchivePath.pathString),
            ("destination", sdk.destination),
        ].map(XcodeBuildOption.init(key:value:))
    }

    var environmentVariables: [XcodeBuildEnvironmentVariable] {
        [
            ("BUILD_DIR", package.workspaceDirectory.pathString),
            ("SKIP_INSTALL", "NO"),
        ].map(XcodeBuildEnvironmentVariable.init(key:value:))
    }
}

extension ArchiveCommand {
    private var xcArchivePath: AbsolutePath {
        buildXCArchivePath(package: package, target: target, sdk: sdk)
    }

    private var projectPath: AbsolutePath {
        package.projectPath
    }
}
