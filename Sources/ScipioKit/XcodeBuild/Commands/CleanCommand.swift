import TSCBasic

struct CleanCommand: XcodeBuildCommand {
    var projectPath: AbsolutePath
    var buildDirectory: AbsolutePath

    let subCommand = "clean"

    var options: [XcodeBuildOption] {
        [.init(key: "project", value: projectPath.pathString)]
    }

    var environmentVariables: [XcodeBuildEnvironmentVariable] {
        [.init(key: "BUILD_DIR", value: buildDirectory.pathString)]
    }
}
