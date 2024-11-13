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
typealias ScipioAbsolutePath = TSCBasic.AbsolutePath
typealias SwiftPMAbsolutePath = Basics.AbsolutePath

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

typealias ScipioResolvedModule = ResolvedModule
typealias ScipioSwiftModule = SwiftModule
typealias ScipioClangModule = ClangModule
typealias ScipioBinaryModule = BinaryModule
