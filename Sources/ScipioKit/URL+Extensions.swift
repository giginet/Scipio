import Foundation
import TSCBasic

extension URL {
    var absolutePath: AbsolutePath {
        precondition(absoluteURL.isFileURL)
        return try! AbsolutePath(validating: path)
    }
}
