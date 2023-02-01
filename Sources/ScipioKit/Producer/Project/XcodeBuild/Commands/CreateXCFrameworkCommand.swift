import Foundation
import PackageGraph

struct CreateXCFrameworkCommand: XcodeBuildCommand {

    let subCommand = "-create-xcframework"

    var package: Package
    var target: ResolvedTarget
    var buildConfiguration: BuildConfiguration
    var sdks: Set<SDK>
    var debugSymbolPaths: [URL]?
    var outputDir: URL

    var options: [XcodeBuildOption] {
        sdks.map { sdk in
                .init(key: "framework", value: buildFrameworkPath(sdk: sdk).path)
        }
        +
        (debugSymbolPaths.flatMap {
            $0.map { .init(key: "debug-symbols", value: $0.path) }
        } ?? [])
        + [.init(key: "output", value: xcFrameworkPath.path)]
    }

    var environmentVariables: [XcodeBuildEnvironmentVariable] {
        []
    }
}

extension CreateXCFrameworkCommand {
    private var xcFrameworkPath: URL {
        outputDir.appendingPathComponent("\(target.name.packageNamed()).xcframework")
    }

    private func buildFrameworkPath(sdk: SDK) -> URL {
        buildXCArchivePath(package: package, target: target, sdk: sdk)
            .appendingPathComponent("Products")
            .appendingPathComponent("Library")
            .appendingPathComponent("Frameworks")
            .appendingPathComponent("\(target.name.packageNamed()).framework")
    }
}
