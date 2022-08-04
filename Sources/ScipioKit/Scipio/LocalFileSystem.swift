import Foundation
import TSCBasic

class LocalFileSystem: FileSystem {

    func isExecutableFile(_ path: AbsolutePath) -> Bool {
        // Our semantics doesn't consider directories.
        return  (self.isFile(path) || self.isSymlink(path)) && FileManager.default.isExecutableFile(atPath: path.pathString)
    }

    func exists(_ path: AbsolutePath, followSymlink: Bool) -> Bool {
        if followSymlink {
            return FileManager.default.fileExists(atPath: path.pathString)
        }
        return (try? FileManager.default.attributesOfItem(atPath: path.pathString)) != nil
    }

    func isDirectory(_ path: AbsolutePath) -> Bool {
        var isDirectory: ObjCBool = false
        let exists: Bool = FileManager.default.fileExists(atPath: path.pathString, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    func isFile(_ path: AbsolutePath) -> Bool {
        let path = resolveSymlinks(path)
        let attrs = try? FileManager.default.attributesOfItem(atPath: path.pathString)
        return attrs?[.type] as? FileAttributeType == .typeRegular
    }

    func isSymlink(_ path: AbsolutePath) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path.pathString)
        return attrs?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    func getFileInfo(_ path: AbsolutePath) throws -> FileInfo {
        let attrs = try FileManager.default.attributesOfItem(atPath: path.pathString)
        return FileInfo(attrs)
    }

    var currentWorkingDirectory: AbsolutePath? {
        let cwdStr = FileManager.default.currentDirectoryPath

#if _runtime(_ObjC)
        // The ObjC runtime indicates that the underlying Foundation has ObjC
        // interoperability in which case the return type of
        // `fileSystemRepresentation` is different from the Swift implementation
        // of Foundation.
        return try? AbsolutePath(validating: cwdStr)
#else
        let fsr: UnsafePointer<Int8> = cwdStr.fileSystemRepresentation
        defer { fsr.deallocate() }

        return try? AbsolutePath(validating: String(cString: fsr))
#endif
    }

    func changeCurrentWorkingDirectory(to path: AbsolutePath) throws {
        guard isDirectory(path) else {
            throw FileSystemError(.notDirectory, path)
        }

        guard FileManager.default.changeCurrentDirectoryPath(path.pathString) else {
            throw FileSystemError(.unknownOSError, path)
        }
    }

    var homeDirectory: AbsolutePath {
        return AbsolutePath(NSHomeDirectory())
    }

    var cachesDirectory: AbsolutePath? {
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first.flatMap { AbsolutePath($0.path) }
    }

    var tempDirectory: AbsolutePath {
        let override = ProcessEnv.vars["TMPDIR"] ?? ProcessEnv.vars["TEMP"] ?? ProcessEnv.vars["TMP"]
        if let path = override.flatMap({ try? AbsolutePath(validating: $0) }) {
            return path
        }
        return AbsolutePath(NSTemporaryDirectory())
    }

    func getDirectoryContents(_ path: AbsolutePath) throws -> [String] {
#if canImport(Darwin)
        return try FileManager.default.contentsOfDirectory(atPath: path.pathString)
#else
        do {
            return try FileManager.default.contentsOfDirectory(atPath: path.pathString)
        } catch let error as NSError {
            // Fixup error from corelibs-foundation.
            if error.code == CocoaError.fileReadNoSuchFile.rawValue, !error.userInfo.keys.contains(NSLocalizedDescriptionKey) {
                var userInfo = error.userInfo
                userInfo[NSLocalizedDescriptionKey] = "The folder “\(path.basename)” doesn’t exist."
                throw NSError(domain: error.domain, code: error.code, userInfo: userInfo)
            }
            throw error
        }
#endif
    }

    func createDirectory(_ path: AbsolutePath, recursive: Bool) throws {
        // Don't fail if path is already a directory.
        if isDirectory(path) { return }

        try FileManager.default.createDirectory(atPath: path.pathString, withIntermediateDirectories: recursive, attributes: [:])
    }

    func createSymbolicLink(_ path: AbsolutePath, pointingAt destination: AbsolutePath, relative: Bool) throws {
        let destString = relative ? destination.relative(to: path.parentDirectory).pathString : destination.pathString
        try FileManager.default.createSymbolicLink(atPath: path.pathString, withDestinationPath: destString)
    }

    func readFileContents(_ path: AbsolutePath) throws -> ByteString {
        // Open the file.
        let fp = fopen(path.pathString, "rb")
        if fp == nil {
            throw FileSystemError(errno: errno, path)
        }
        defer { fclose(fp) }

        // Read the data one block at a time.
        let data = BufferedOutputByteStream()
        var tmpBuffer = [UInt8](repeating: 0, count: 1 << 12)
        while true {
            let n = fread(&tmpBuffer, 1, tmpBuffer.count, fp)
            if n < 0 {
                if errno == EINTR { continue }
                throw FileSystemError(.ioError(code: errno), path)
            }
            if n == 0 {
                let errno = ferror(fp)
                if errno != 0 {
                    throw FileSystemError(.ioError(code: errno), path)
                }
                break
            }
            data <<< tmpBuffer[0..<n]
        }

        return data.bytes
    }

    func writeFileContents(_ path: AbsolutePath, bytes: ByteString) throws {
        // Open the file.
        let fp = fopen(path.pathString, "wb")
        if fp == nil {
            throw FileSystemError(errno: errno, path)
        }
        defer { fclose(fp) }

        // Write the data in one chunk.
        var contents = bytes.contents
        while true {
            let n = fwrite(&contents, 1, contents.count, fp)
            if n < 0 {
                if errno == EINTR { continue }
                throw FileSystemError(.ioError(code: errno), path)
            }
            if n != contents.count {
                throw FileSystemError(.unknownOSError, path)
            }
            break
        }
    }

    func writeFileContents(_ path: AbsolutePath, bytes: ByteString, atomically: Bool) throws {
        // Perform non-atomic writes using the fast path.
        if !atomically {
            return try writeFileContents(path, bytes: bytes)
        }

        try bytes.withData {
            try $0.write(to: URL(fileURLWithPath: path.pathString), options: .atomic)
        }
    }

    func removeFileTree(_ path: AbsolutePath) throws {
        do {
            try FileManager.default.removeItem(atPath: path.pathString)
        } catch let error as NSError {
            // If we failed because the directory doesn't actually exist anymore, ignore the error.
            if !(error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError) {
                throw error
            }
        }
    }

    func chmod(_ mode: FileMode, path: AbsolutePath, options: Set<FileMode.Option>) throws {
        assertionFailure()
    }

    func copy(from sourcePath: AbsolutePath, to destinationPath: AbsolutePath) throws {
        guard exists(sourcePath) else { throw FileSystemError(.noEntry, sourcePath) }
        guard !exists(destinationPath)
        else { throw FileSystemError(.alreadyExistsAtDestination, destinationPath) }
        try FileManager.default.copyItem(at: sourcePath.asURL, to: destinationPath.asURL)
    }

    func move(from sourcePath: AbsolutePath, to destinationPath: AbsolutePath) throws {
        guard exists(sourcePath) else { throw FileSystemError(.noEntry, sourcePath) }
        guard !exists(destinationPath)
        else { throw FileSystemError(.alreadyExistsAtDestination, destinationPath) }
        try FileManager.default.moveItem(at: sourcePath.asURL, to: destinationPath.asURL)
    }

    func withLock<T>(on path: AbsolutePath, type: FileLock.LockType = .exclusive, _ body: () throws -> T) throws -> T {
        try FileLock.withLock(fileToLock: path, type: type, body: body)
    }
}
