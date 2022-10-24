import Foundation

public protocol FileSystem {
    var currentWorkingDirectory: URL? { get }
    var cachesDirectory: URL? { get }

    func exists(_ path: URL) -> Bool
    func contents(of path: URL) -> Data?

    @discardableResult func write(_ data: Data, to path: URL) -> Bool
    @discardableResult func changeCurrentWorkingDirectory(to destination: URL) -> Bool
    func createDirectory(_ path: URL, recursive: Bool) throws
    func copy(from source: URL, to destination: URL) throws
    func removeFileTree(at path: URL) throws
}

public let localFileSystem: some FileSystem = LocalFileSystem()

struct LocalFileSystem: FileSystem {
    private let fileManager: FileManager = .default

    fileprivate init() { }

    func write(_ data: Data, to path: URL) -> Bool {
        fileManager.createFile(atPath: path.path,
                               contents: data)
    }

    func exists(_ path: URL) -> Bool {
        fileManager.fileExists(atPath: path.path)
    }

    func contents(of path: URL) -> Data? {
        fileManager.contents(atPath: path.path)
    }

    func changeCurrentWorkingDirectory(to destination: URL) -> Bool {
        fileManager.changeCurrentDirectoryPath(destination.path)
    }

    var currentWorkingDirectory: URL? {
        URL(fileURLWithPath: fileManager.currentDirectoryPath)
    }

    func createDirectory(_ path: URL, recursive: Bool) throws {
        try fileManager.createDirectory(at: path, withIntermediateDirectories: recursive)
    }

    func copy(from source: URL, to destination: URL) throws {
        try fileManager.copyItem(at: source, to: destination)
    }

    var cachesDirectory: URL? {
        fileManager.urls(for: .cachesDirectory,
                         in: .userDomainMask).first
    }

    func removeFileTree(at path: URL) throws {
        try fileManager.removeItem(at: path)
    }
}
