import TSCBasic
import Foundation

extension FileSystem {
    func writeFileContents(_ path: AbsolutePath, data: Data) throws {
        try self.writeFileContents(path, bytes: .init(data))
    }

    func writeFileContents(_ path: AbsolutePath, string: String) throws {
        try self.writeFileContents(path, bytes: .init(encodingAsUTF8: string))
    }

    func readFileContents(_ path: AbsolutePath) throws -> Data {
        try Data(self.readFileContents(path).contents)
    }
}

extension JSONDecoder {
    func decode<T: Decodable>(path: AbsolutePath, fileSystem: FileSystem, as kind: T.Type) throws -> T {
        let data: Data = try fileSystem.readFileContents(path)
        return try self.decode(kind, from: data)
    }
}
