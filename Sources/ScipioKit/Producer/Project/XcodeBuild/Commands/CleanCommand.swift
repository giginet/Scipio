import Foundation

struct CleanCommand: XcodeBuildCommand {

    let subCommand = "clean"

    var package: Package

    var options: [XcodeBuildOption] {
        [.init(key: "project", value: package.projectPath.path)]
    }

    var environmentVariables: [XcodeBuildEnvironmentVariable] {
        [.init(key: "BUILD_DIR", value: package.workspaceDirectory.path)]
    }
}
