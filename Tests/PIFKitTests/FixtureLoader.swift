import Foundation

enum FixtureLoader {
    static func load(named filename: String) throws -> Data {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .appending(components: "Fixtures", filename)
        return try Data(contentsOf: url)
    }
}
