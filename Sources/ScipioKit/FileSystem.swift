import Foundation

public protocol FileSystem: Sendable {
    var tempDirectory: URL { get }
    var cachesDirectory: URL? { get async }
    var currentWorkingDirectory: URL? { get async }

    func writeFileContents(_ path: URL, data: Data) async throws
    func readFileContents(_ path: URL) async throws -> Data
    func exists(_ path: URL, followSymlink: Bool) async -> Bool
    func isDirectory(_ path: URL) async -> Bool
    func isFile(_ path: URL) async -> Bool
    func isSymlink(_ path: URL) -> Bool
    func copy(from fromURL: URL, to toURL: URL) async throws
    func createDirectory(_ directoryPath: URL, recursive: Bool) async throws
    func move(from fromURL: URL, to toURL: URL) async throws
    func getDirectoryContents(_ directoryPath: URL) async throws -> [String]
    func removeFileTree(_ path: URL) async throws
}

extension FileSystem {
    func createDirectory(_ directoryPath: URL) async throws {
        try await createDirectory(directoryPath, recursive: false)
    }

    func writeFileContents(_ path: URL, string: String) async throws {
        let data = string.data(using: .utf8)!
        try await writeFileContents(path, data: data)
    }

    func exists(_ path: URL) async -> Bool {
        await exists(path, followSymlink: true)
    }
}

public actor LocalFileSystem: FileSystem {
    nonisolated public static let `default` = LocalFileSystem()

    public init() {}

    private let fileManager = FileManager.default

    nonisolated public var tempDirectory: URL {
        URL(filePath: NSTemporaryDirectory())
    }

    public var cachesDirectory: URL? {
        get async {
            fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        }
    }

    public var currentWorkingDirectory: URL? {
        get async {
            URL(filePath: fileManager.currentDirectoryPath)
        }
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
        guard let contents = fileManager.contents(atPath: path.path(percentEncoded: false)) else {
            throw FileSystemError.cannotReadFileContents(path: path)
        }
        return contents
    }

    public func exists(_ path: URL, followSymlink: Bool = true) -> Bool {
        if followSymlink {
            return fileManager.fileExists(atPath: path.path(percentEncoded: false))
        }
        return (try? fileManager.attributesOfItem(atPath: path.path(percentEncoded: false))) != nil
    }

    public func isDirectory(_ path: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: path.path(percentEncoded: false), isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    public func isFile(_ path: URL) -> Bool {
        let path = path.resolvingSymlinksInPath()
        let attributes = try? fileManager.attributesOfItem(atPath: path.path(percentEncoded: false))
        return attributes?[.type] as? FileAttributeType == .typeRegular
    }

    public nonisolated func isSymlink(_ path: URL) -> Bool {
        let values = try? path.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values?.isSymbolicLink == true
    }

    public func copy(from fromURL: URL, to toURL: URL) throws {
        try fileManager.copyItem(at: fromURL, to: toURL)
    }

    public func createDirectory(_ directoryPath: URL, recursive: Bool) throws {
        try fileManager.createDirectory(
            at: directoryPath,
            withIntermediateDirectories: recursive
        )
    }

    public func move(from fromURL: URL, to toURL: URL) throws {
        try fileManager.moveItem(at: fromURL, to: toURL)
    }

    public func getDirectoryContents(_ directoryPath: URL) throws -> [String] {
        try fileManager.contentsOfDirectory(atPath: directoryPath.path(percentEncoded: false))
    }

    public func removeFileTree(_ path: URL) throws {
        do {
            try fileManager.removeItem(atPath: path.path(percentEncoded: false))
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
