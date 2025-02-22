import Foundation

enum FixtureLoader {
    static func load(named filename: String) -> Data? {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .appending(components: "Fixtures", filename)
        let fileManager = FileManager.default
        return fileManager.contents(atPath: url.path)
    }
}
