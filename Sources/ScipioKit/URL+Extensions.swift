import Foundation
import TSCBasic

extension URL {
    var absolutePath: AbsolutePath {
        return try! AbsolutePath(validating: path)
    }

    var spmAbsolutePath: SwiftPMAbsolutePath {
        return try! SwiftPMAbsolutePath(validating: path)
    }
}
