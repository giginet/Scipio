import Foundation
import ArgumentParser
import ScipioKit

struct GlobalOptionGroup: ParsableArguments {
    @Flag(name: [.short, .long],
          help: "Provide additional build progress.")
    var verbose: Bool = false
}

struct BuildOptionGroup: ParsableArguments {
    @Option(name: [.customShort("o"), .customLong("output")],
            help: "Path indicates a XCFrameworks output directory.")
    var customOutputDirectory: URL?

    @Option(name: [.customLong("configuration"), .customShort("c")],
            help: "Build configuration for generated frameworks. (debug / release)")
    var buildConfiguration: BuildConfiguration = .release

    @Flag(name: .customLong("embed-debug-symbols"),
          help: "Whether embed debug symbols to frameworks or not.")
    var embedDebugSymbols = false

    @Flag(name: .customLong("support-simulators"),
          help: "Whether also building for simulators of each SDKs or not.")
    var supportSimulators = false

    @Flag(name: [.customLong("--static")],
          help: "Whether generated frameworks is a Static Framework or not")
    var shouldBuildStaticFramework = false
}

extension BuildOptionGroup {
    var frameworkType: FrameworkType {
        shouldBuildStaticFramework ? .static : .dynamic
    }
}
