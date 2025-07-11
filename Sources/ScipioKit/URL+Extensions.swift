import Foundation

/// Extensions for compatibility with TSC's Path implementation.
extension URL {
    // ref: https://github.com/swiftlang/swift-tools-support-core/blob/f9b401016b70c6b8409e5c97e74d97513d1a8d02/Sources/TSCBasic/Path.swift#L598-L614
    var dirname: String {
        var path = self.standardizedFileURL.path(percentEncoded: false)
        // Normalize path by removing trailing '/' to treat '/path/to/' and '/path/to' equivalently
        if path.hasSuffix("/") && path != "/" {
            path.removeLast()
        }
        guard let idx = path.lastIndex(of: "/") else {
            // No path separators, so directory is current directory
            return "."
        }
        // If the only separator is the first character, it's the root directory
        if idx == path.startIndex {
            return "/"
        }
        // Otherwise, return everything up to (but not including) the last separator
        return String(path.prefix(upTo: idx))
    }

    // ref: https://github.com/swiftlang/swift-tools-support-core/blob/f9b401016b70c6b8409e5c97e74d97513d1a8d02/Sources/TSCBasic/Path.swift#L661-L663
    var parentDirectory: URL {
        path(percentEncoded: false) == "/" ? self : URL(filePath: dirname)
    }

    func appending(components: [String]) -> URL {
        components.reduce(self) { $0.appending(component: $1) }
    }
}
