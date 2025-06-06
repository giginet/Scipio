import Foundation
import TSCBasic

extension URL {
    var absolutePath: AbsolutePath {
        return try! AbsolutePath(validating: path)
    }
}
