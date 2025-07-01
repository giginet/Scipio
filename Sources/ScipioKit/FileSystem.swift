import Foundation

/// Provides abstracted access to file system operations.
public protocol FileSystem: Sendable {
    /// The URL of the temporary directory (e.g., NSTemporaryDirectory()).
    var tempDirectory: URL { get }

    /// The URL of the user's caches directory, if available.
    var cachesDirectory: URL? { get }

    /// The current working directory, similar to getcwd(3).
    /// May be nil if the directory is unavailable.
    var currentWorkingDirectory: URL? { get }

    /// Writes data to a file at the specified URL.
    /// Creates parent directories if needed.
    /// - Parameter path: The file URL to write to.
    /// - Parameter data: The raw data to write.
    func writeFileContents(_ path: URL, data: Data) throws

    /// Reads and returns the contents of the file at the specified URL.
    /// - Parameter path: The file URL to read from.
    /// - Returns: The file contents as Data.
    func readFileContents(_ path: URL) throws -> Data

    /// Checks whether the given path exists.
    /// - Parameters:
    ///   - path: The URL to check.
    ///   - followSymlink: If true, symlinks will be resolved.
    /// - Returns: True if the path exists.
    func exists(_ path: URL, followSymlink: Bool) -> Bool

    /// Determines if the given URL is an existing directory.
    /// - Parameter path: The URL to check.
    func isDirectory(_ path: URL) -> Bool

    /// Determines if the given URL is an existing regular file.
    /// - Parameter path: The URL to check.
    func isFile(_ path: URL) -> Bool

    /// Determines if the given URL is a symbolic link.
    /// - Parameter path: The URL to check.
    func isSymlink(_ path: URL) -> Bool

    /// Copies an item from one URL to another.
    /// - Parameters:
    ///   - fromURL: The source URL.
    ///   - toURL: The destination URL.
    func copy(from fromURL: URL, to toURL: URL) throws

    /// Creates a directory at the specified URL.
    /// - Parameters:
    ///   - directoryPath: The directory URL to create.
    ///   - recursive: If true, create intermediate directories as needed.
    func createDirectory(_ directoryPath: URL, recursive: Bool) throws

    /// Moves an item from one URL to another.
    /// - Parameters:
    ///   - fromURL: The source URL.
    ///   - toURL: The destination URL.
    func move(from fromURL: URL, to toURL: URL) throws

    /// Returns the names of items in the specified directory.
    /// - Parameter directoryPath: The directory URL to list.
    /// - Returns: An array of file and directory names; order is undefined.
    func getDirectoryContents(_ directoryPath: URL) throws -> [String]

    /// Recursively removes the file or directory at the specified URL.
    /// No error is thrown if the item does not exist.
    /// - Parameter path: The URL of the item to remove.
    func removeFileTree(_ path: URL) throws
}

extension FileSystem {
    /// Creates a directory at the specified URL without creating intermediate directories.
    /// - Parameter directoryPath: The directory URL to create.
    /// - Throws: An error if directory creation fails.
    func createDirectory(_ directoryPath: URL) throws {
        try createDirectory(directoryPath, recursive: false)
    }

    /// Writes a UTF-8 encoded string to the file at the specified URL.
    /// - Parameters:
    ///   - path: The file URL to write to.
    ///   - string: The string content to write.
    /// - Throws: An error if the write operation fails.
    func writeFileContents(_ path: URL, string: String) throws {
        guard let data = string.data(using: .utf8) else {
            throw FileSystemError.utf8EncodingFailed
        }
        try writeFileContents(path, data: data)
    }

    /// Checks if the item at the specified URL exists, following symbolic links.
    /// - Parameter path: The URL to check.
    /// - Returns: True if the path exists; false otherwise.
    func exists(_ path: URL) -> Bool {
        exists(path, followSymlink: true)
    }
}

public struct LocalFileSystem: FileSystem {
    public static let `default` = LocalFileSystem()

    public var tempDirectory: URL {
        FileManager.default.temporaryDirectory
    }

    public var cachesDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }

    public var currentWorkingDirectory: URL? {
        URL(filePath: FileManager.default.currentDirectoryPath)
    }

    public func writeFileContents(_ path: URL, data: Data) throws {
        guard path.isFileURL else {
            throw FileSystemError.invalidFileURL(path: path)
        }

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
        guard exists(fromURL) else {
            throw FileSystemError.entryNotFound(path: fromURL)
        }
        guard !exists(toURL) else {
            throw FileSystemError.alreadyExistsAtDestination(path: toURL)
        }
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
            // If we failed because the directory doesn't actually exist anymore, ignore the error.
            if !(error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError) {
                throw error
            }
        }
    }
}

public enum FileSystemError: LocalizedError {
    case invalidFileURL(path: URL)
    case cannotReadFileContents(path: URL)
    case utf8EncodingFailed
    case entryNotFound(path: URL)
    case alreadyExistsAtDestination(path: URL)

    public var errorDescription: String? {
        switch self {
        case .invalidFileURL(let path):
            "Cannot write to \"\(path.path)\": the URL must be a file URL."
        case .cannotReadFileContents(let path):
            "Failed to read file contents at path \(path.path)"
        case .utf8EncodingFailed:
            "Failed to convert the command output string to UTF-8 encoded data"
        case .entryNotFound(let path):
            "No file system entry found at \"\(path.path)\"."
        case .alreadyExistsAtDestination(let path):
            "Cannot copy: destination already exists at \"\(path.path)\"."
        }
    }
}
