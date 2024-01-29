import Foundation
import TSCBasic
import Basics

// TODO: Remove TSCBasics
// Since Swift 5.10, SwiftPM removes swift-tools-support-core(TSC)
// So all interfaces are replaced from TSCBasics.AbsolutePath to Basics.AbsolutePath
// These are almost identical. Unfortunately, Scipio still uses TSC versions of them.
// It's better to remove TSC dependencies from Scipio.
// However we just provides utils to bridge them at this time
#if swift(>=5.10)

typealias ScipioAbsolutePath = TSCBasic.AbsolutePath
typealias SwiftPMAbsolutePath = Basics.AbsolutePath

#else

// Below Swift 5.9, Basics.AbsolutePath is not implemented. So this is required to keep backward-compatibility

typealias ScipioAbsolutePath = TSCBasic.AbsolutePath
typealias SwiftPMAbsolutePath = TSCBasic.AbsolutePath

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
