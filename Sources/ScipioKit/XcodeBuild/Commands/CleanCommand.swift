import TSCBasic

struct CleanCommand: XcodeBuildCommand {

    let subCommand = "clean"

    var package: Package

    var options: [XcodeBuildOption] {
        [.init(key: "project", value: package.projectPath.pathString)]
    }

    var environmentVariables: [XcodeBuildEnvironmentVariable] {
        [.init(key: "BUILD_DIR", value: package.workspaceDirectory.pathString)]
    }
}
