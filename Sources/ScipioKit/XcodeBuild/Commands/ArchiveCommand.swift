import TSCBasic
import PackageGraph

struct ArchiveCommand: XcodeBuildCommand {

    struct Context: XcodeBuildContext {
        var package: Package
        var target: ResolvedTarget
        var buildConfiguration: BuildConfiguration
        var sdk: SDK
    }

    var context: Context

    let subCommand = "archive"

    var options: [XcodeBuildOption] {
        [
            ("project", context.projectPath.pathString),
            ("configuration", context.buildConfiguration.settingsValue),
            ("scheme", context.target.name),
            ("archivePath", xcArchivePath.pathString),
            ("destination", context.sdk.destination),
        ].map(XcodeBuildOption.init(key:value:))
    }

    var environmentVariables: [XcodeBuildEnvironmentVariable] {
        [
            ("BUILD_DIR", context.package.workspaceDirectory.pathString),
            ("SKIP_INSTALL", "NO"),
        ].map(XcodeBuildEnvironmentVariable.init(key:value:))
    }
}

extension ArchiveCommand {
    var xcArchivePath: AbsolutePath {
        context.xcArchivePath
    }
}

extension ArchiveCommand.Context {
    var xcArchivePath: AbsolutePath {
        buildXCArchivePath(sdk: sdk)
    }
}
