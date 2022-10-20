import TSCBasic
import PackageGraph

struct CreateXCFrameworkCommand: XcodeBuildCommand {
    struct Context: XcodeBuildContext {
        var package: Package
        var target: ResolvedTarget
        var buildConfiguration: BuildConfiguration
        var sdks: Set<SDK>
        var debugSymbolPaths: [AbsolutePath]?
    }

    var context: Context

    let subCommand = "-create-xcframework"

    var outputDir: AbsolutePath

    var options: [XcodeBuildOption] {
        context.sdks.map { sdk in
                .init(key: "framework", value: buildFrameworkPath(sdk: sdk).pathString)
        }
        +
        (context.debugSymbolPaths.flatMap {
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
        outputDir.appending(component: "\(context.target.name.packageNamed()).xcframework")
    }

    private func buildFrameworkPath(sdk: SDK) -> AbsolutePath {
        context.buildXCArchivePath(sdk: sdk)
            .appending(components: "Products", "Library", "Frameworks")
            .appending(component: "\(context.target.name.packageNamed()).framework")
    }
}
