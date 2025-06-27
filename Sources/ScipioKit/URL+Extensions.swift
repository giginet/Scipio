import Foundation

extension URL {
    var dirname: String {
        let path = self.standardizedFileURL.path
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

    var parentDirectory: URL {
        dirname.isEmpty ? self : deletingLastPathComponent()
    }

    func appending(components: [String]) -> URL {
        components.reduce(self) { $0.appending(component: $1) }
    }
}
