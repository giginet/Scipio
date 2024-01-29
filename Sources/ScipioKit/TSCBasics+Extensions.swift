import Foundation
import TSCBasic
import Basics

extension TSCBasic.AbsolutePath {
    // TODO Replace TSCBasic to Basics in future
    var spm_absolutePath: Basics.AbsolutePath {
        try! Basics.AbsolutePath(validating: pathString)
    }
}
