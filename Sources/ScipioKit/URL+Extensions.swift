import Foundation
import Basics

extension URL {
    var absolutePath: TSCAbsolutePath {
        precondition(absoluteURL.isFileURL)
        return try! TSCAbsolutePath(validating: path)
    }
}
