import Foundation
import PackageGraph
import TSCBasic
import Basics
import PackageModel

// TODO: Remove TSCBasics
// Since Swift 5.10, SwiftPM removes swift-tools-support-core(TSC), 
// so all interfaces are replaced from TSCBasics.AbsolutePath to Basics.AbsolutePath.
// These has almost identical feature and interface. Unfortunately, Scipio still uses TSC versions of them 
// so It's better to remove TSC dependencies from Scipio.
// At this moment, we just provides utils to bridge them at this time as below.
#if swift(>=5.10)

// Above Swift 5.10, SwiftPM requires their own AbsolutePath,
// so we have to bridge them to Scipio requires by typealias

typealias ScipioAbsolutePath = TSCBasic.AbsolutePath
typealias SwiftPMAbsolutePath = Basics.AbsolutePath

#else

// Below Swift 5.9, Basics.AbsolutePath is not implemented yet. So this is required to keep backward-compatibility

typealias ScipioAbsolutePath = TSCBasic.AbsolutePath
typealias SwiftPMAbsolutePath = TSCBasic.AbsolutePath

// In Swift 5.10, Destination is renamed to SwiftSDK, so this is required to keep backward-compatibility
typealias SwiftSDK = Destination

#endif

extension ScipioAbsolutePath {
    var spmAbsolutePath: SwiftPMAbsolutePath {
        try! SwiftPMAbsolutePath(validating: pathString)
    }
}

extension SwiftPMAbsolutePath {
    var scipioAbsolutePath: ScipioAbsolutePath {
        try! ScipioAbsolutePath(validating: pathString)
    }
}

// Since 6.0, all `~Target` has been renamed to `~Module`
#if compiler(>=6.0)

typealias ScipioResolvedModule = ResolvedModule
typealias ScipioSwiftModule = SwiftModule
typealias ScipioClangModule = ClangModule
typealias ScipioBinaryModule = BinaryModule

#else

typealias ScipioResolvedModule = ResolvedTarget
typealias ScipioSwiftModule = SwiftTarget
typealias ScipioClangModule = ClangTarget
typealias ScipioBinaryModule = BinaryTarget

#endif

#if compiler(<6.0)

extension ResolvedProduct {
    var modules: [ResolvedTarget] {
        targets
    }
}

extension ResolvedPackage {
    var modules: [ScipioResolvedModule] {
        targets
    }
}

extension ScipioResolvedModule {
    var underlying: Target {
        underlyingTarget
    }
}

extension ScipioResolvedModule.Dependency {
    var module: ScipioResolvedModule? {
        target
    }
}

#endif

#if compiler(<6.0)

typealias ModulesGraph = PackageGraph

#endif
