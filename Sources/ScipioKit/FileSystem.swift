import Foundation

public protocol FileSystem: Sendable {
    var tempDirectory: URL { get }
    var cachesDirectory: URL? { get }
    var currentWorkingDirectory: URL? { get }

    func writeFileContents(_ path: URL, data: Data) throws
    func readFileContents(_ path: URL) throws -> Data
    func exists(_ path: URL, followSymlink: Bool) -> Bool
    func isDirectory(_ path: URL) -> Bool
    func isFile(_ path: URL) -> Bool
    func isSymlink(_ path: URL) -> Bool
    func copy(from fromURL: URL, to toURL: URL) throws
    func createDirectory(_ directoryPath: URL, recursive: Bool) throws
    func move(from fromURL: URL, to toURL: URL) throws
    func getDirectoryContents(_ directoryPath: URL) throws -> [String]
    func removeFileTree(_ path: URL) throws
}

extension FileSystem {
    func createDirectory(_ directoryPath: URL) throws {
        try createDirectory(directoryPath, recursive: false)
    }

    func writeFileContents(_ path: URL, string: String) throws {
        let data = string.data(using: .utf8)!
        try writeFileContents(path, data: data)
    }

    func exists(_ path: URL) -> Bool {
        exists(path, followSymlink: true)
    }
}

public struct LocalFileSystem: FileSystem {
    public static let `default` = LocalFileSystem()

    public var tempDirectory: URL {
        URL(filePath: NSTemporaryDirectory())
    }

    public var cachesDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }

    public var currentWorkingDirectory: URL? {
        URL(filePath: FileManager.default.currentDirectoryPath)
    }

    public func writeFileContents(_ path: URL, data: Data) throws {
        if !exists(path) {
            try createDirectory(
                path.deletingLastPathComponent(),
                recursive: true
            )
        }
        try data.write(to: path, options: .atomic)
    }

    public func readFileContents(_ path: URL) throws -> Data {
        guard let contents = FileManager.default.contents(atPath: path.path(percentEncoded: false)) else {
            throw FileSystemError.cannotReadFileContents(path: path)
        }
        return contents
    }

    public func exists(_ path: URL, followSymlink: Bool = true) -> Bool {
        if followSymlink {
            return FileManager.default.fileExists(atPath: path.path(percentEncoded: false))
        }
        return (try? FileManager.default.attributesOfItem(atPath: path.path(percentEncoded: false))) != nil
    }

    public func isDirectory(_ path: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path.path(percentEncoded: false), isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    public func isFile(_ path: URL) -> Bool {
        let path = path.resolvingSymlinksInPath()
        let attributes = try? FileManager.default.attributesOfItem(atPath: path.path(percentEncoded: false))
        return attributes?[.type] as? FileAttributeType == .typeRegular
    }

    public func isSymlink(_ path: URL) -> Bool {
        let values = try? path.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values?.isSymbolicLink == true
    }

    public func copy(from fromURL: URL, to toURL: URL) throws {
        try FileManager.default.copyItem(at: fromURL, to: toURL)
    }

    public func createDirectory(_ directoryPath: URL, recursive: Bool) throws {
        try FileManager.default.createDirectory(
            at: directoryPath,
            withIntermediateDirectories: recursive
        )
    }

    public func move(from fromURL: URL, to toURL: URL) throws {
        try FileManager.default.moveItem(at: fromURL, to: toURL)
    }

    public func getDirectoryContents(_ directoryPath: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directoryPath.path(percentEncoded: false))
    }

    public func removeFileTree(_ path: URL) throws {
        do {
            try FileManager.default.removeItem(atPath: path.path(percentEncoded: false))
        } catch let error as NSError {
            if !(error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError) {
                throw error
            }
        }
    }
}

public enum FileSystemError: LocalizedError {
    case cannotReadFileContents(path: URL)

    public var errorDescription: String? {
        switch self {
        case .cannotReadFileContents(let path):
            return "Failed to read file contents at path \(path.path)"
        }
    }
}
