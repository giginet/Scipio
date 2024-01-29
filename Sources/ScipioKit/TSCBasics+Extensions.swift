import Foundation
import TSCBasic
import Basics

// TODO: Remove TSCBasics
// Since Swift 5.10, SwiftPM removes swift-tools-support-core(TSC)
// So all interfaces are replaced from TSCBasics.AbsolutePath to Basics.AbsolutePath
// These are almost identical. Unfortunately, Scipio still uses TSC versions of them.
// It's better to remove TSC dependencies from Scipio.
// However we just provides utils to bridge them at this time

extension TSCBasic.AbsolutePath {
    var spm_absolutePath: Basics.AbsolutePath {
        try! Basics.AbsolutePath(validating: pathString)
    }
}

extension Basics.AbsolutePath {
    var tsc_absolutePath: TSCBasic.AbsolutePath {
        try! TSCBasic.AbsolutePath(validating: pathString)
    }
}
