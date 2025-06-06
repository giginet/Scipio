import Foundation
import TSCBasic

extension URL {
    var absolutePath: TSCAbsolutePath {
        return try! TSCAbsolutePath(validating: path)
    }

    var spmAbsolutePath: SwiftPMAbsolutePath {
        return try! SwiftPMAbsolutePath(validating: path)
    }
}
