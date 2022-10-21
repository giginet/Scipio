import TSCBasic
import PackageGraph

struct CreateXCFrameworkCommand: XcodeBuildCommand {

    let subCommand = "-create-xcframework"

    var package: Package
    var target: ResolvedTarget
    var buildConfiguration: BuildConfiguration
    var sdks: Set<SDK>
    var debugSymbolPaths: [AbsolutePath]?
    var outputDir: AbsolutePath

    var options: [XcodeBuildOption] {
        sdks.map { sdk in
                .init(key: "framework", value: buildFrameworkPath(sdk: sdk).pathString)
        }
        +
        (debugSymbolPaths.flatMap {
            $0.map { .init(key: "debug-symbols", value: $0.pathString) }
        } ?? [])
        + [.init(key: "output", value: xcFrameworkPath.pathString)]
    }

    var environmentVariables: [XcodeBuildEnvironmentVariable] {
        []
    }
}

extension CreateXCFrameworkCommand {
    private var xcFrameworkPath: AbsolutePath {
        outputDir.appending(component: "\(target.name.packageNamed()).xcframework")
    }

    private func buildFrameworkPath(sdk: SDK) -> AbsolutePath {
        buildXCArchivePath(package: package, target: target, sdk: sdk)
            .appending(components: "Products", "Library", "Frameworks")
            .appending(component: "\(target.name.packageNamed()).framework")
    }
}
