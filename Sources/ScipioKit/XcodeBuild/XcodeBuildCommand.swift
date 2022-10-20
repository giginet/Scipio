import PackageGraph
import TSCBasic

protocol XcodeBuildCommand {
    var subCommand: String { get }
    var options: [XcodeBuildOption] { get }
    var environmentVariables: [XcodeBuildEnvironmentVariable] { get }
}

extension XcodeBuildCommand {
    func buildArguments() -> [String] {
        ["/usr/bin/xcrun", "xcodebuild"]
        + environmentVariables.map { pair in "\(pair.key)=\(pair.value)" }
        + [subCommand]
        + options.flatMap { option in ["-\(option.key)", option.value] }
            .compactMap { $0 }
    }
}

struct XcodeBuildOption {
    var key: String
    var value: String?
}

struct XcodeBuildEnvironmentVariable {
    var key: String
    var value: String
}

protocol XcodeBuildContext {
    var package: Package { get }
    var target: ResolvedTarget { get }
    var buildConfiguration: BuildConfiguration { get }
}

extension XcodeBuildContext {
    func buildXCArchivePath(sdk: SDK) -> AbsolutePath {
        package.archivesPath.appending(component: "\(target.name)_\(sdk.name).xcarchive")
    }

    var projectPath: AbsolutePath {
        package.projectPath
    }
}
