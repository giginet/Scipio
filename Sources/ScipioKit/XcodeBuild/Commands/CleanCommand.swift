import TSCBasic

struct CleanCommand: XcodeBuildCommand {

    let subCommand = "clean"

    var projectPath: AbsolutePath
    var buildDirectory: AbsolutePath

    var options: [XcodeBuildOption] {
        [.init(key: "project", value: projectPath.pathString)]
    }

    var environmentVariables: [XcodeBuildEnvironmentVariable] {
        [.init(key: "BUILD_DIR", value: buildDirectory.pathString)]
    }
}
