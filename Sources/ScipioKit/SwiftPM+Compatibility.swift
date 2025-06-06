import Foundation
import TSCBasic

// TODO: Remove TSCBasics
// Since Swift 5.10, SwiftPM removes swift-tools-support-core(TSC), 
// so all interfaces are replaced from TSCBasics.AbsolutePath to Basics.AbsolutePath.
// These has almost identical feature and interface. Unfortunately, Scipio still uses TSC versions of them 
// so It's better to remove TSC dependencies from Scipio.
// At this moment, we just provides utils to bridge them at this time as below.
typealias SwiftPMAbsolutePath = Basics.AbsolutePath

extension AbsolutePath {
    var spmAbsolutePath: SwiftPMAbsolutePath {
        SwiftPMAbsolutePath(self)
    }
}

extension SwiftPMAbsolutePath {
    var scipioAbsolutePath: AbsolutePath {
        try! AbsolutePath(validating: pathString)
    }
}
