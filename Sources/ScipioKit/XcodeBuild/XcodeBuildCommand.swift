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
