import Foundation
import TSCBasic
import Basics
import PackageModel

// TODO: Remove TSCBasics
// Since Swift 5.10, SwiftPM removes swift-tools-support-core(TSC)
// So all interfaces are replaced from TSCBasics.AbsolutePath to Basics.AbsolutePath
// These are almost identical. Unfortunately, Scipio still uses TSC versions of them.
// It's better to remove TSC dependencies from Scipio.
// However we just provides utils to bridge them at this time
#if swift(>=5.10)

// Above Swift 5.10, SwiftPM requires their own AbsolutePath
// So we have to convert them to Scipio requires

typealias ScipioAbsolutePath = TSCBasic.AbsolutePath
typealias SwiftPMAbsolutePath = Basics.AbsolutePath

#else

// Below Swift 5.9, Basics.AbsolutePath is not implemented yet. So this is required to keep backward-compatibility

typealias ScipioAbsolutePath = TSCBasic.AbsolutePath
typealias SwiftPMAbsolutePath = TSCBasic.AbsolutePath

// Since Swift 5.10, Destination is renamed to SwiftSDK
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
