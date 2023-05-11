import Foundation
import System
import Compression
import AppleArchive

struct Compressor {
    private let fileManager: FileManager = .default

    init() {
        try? fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    func compress(_ directoryPath: URL) throws -> Data {
        guard let keySet else { throw Error.initializationError }

        let source = FilePath(directoryPath.path)

        let archivePath = temporaryDirectory.appendingPathComponent("\(UUID().uuidString).aar")
        defer { try? fileManager.removeItem(at: archivePath) }

        try ArchiveByteStream.withFileStream(
            path: FilePath(archivePath.path),
            mode: .writeOnly,
            options: [.create, .truncate],
            permissions: [.ownerReadWrite, .groupRead, .otherRead]
        ) { file in
            try ArchiveByteStream.withCompressionStream(using: .lzfse, writingTo: file) { compressor in
                try ArchiveStream.withEncodeStream(writingTo: compressor) { encoder in
                    try encoder.writeDirectoryContents(archiveFrom: source, keySet: keySet)
                }
            }
        }

        guard let data = fileManager.contents(atPath: archivePath.path) else {
            throw Error.compressionError
        }

        return data
    }

    func extract(_ archiveData: Data, to destinationPath: URL) throws {
        let destination = FilePath(destinationPath.path)

        let temporaryPath = temporaryDirectory.appendingPathComponent("\(UUID().uuidString).aar")
        fileManager.createFile(atPath: temporaryPath.path, contents: archiveData)
        defer { try? fileManager.removeItem(at: temporaryPath) }

        try fileManager.createDirectory(at: destinationPath, withIntermediateDirectories: true)

        _ = try ArchiveByteStream.withFileStream(
            path: FilePath(temporaryPath.path),
            mode: .readOnly,
            options: [],
            permissions: [.ownerRead, .groupRead, .otherRead]
        ) { file in
            try ArchiveByteStream.withDecompressionStream(readingFrom: file) { decompress in
                try ArchiveStream.withDecodeStream(readingFrom: decompress) { decode in
                    try ArchiveStream.withExtractStream(
                        extractingTo: destination,
                        flags: [.ignoreOperationNotPermitted]
                    ) { extract in
                        try ArchiveStream.process(readingFrom: decode, writingTo: extract)
                    }
                }
            }
        }
    }

    enum Error: LocalizedError {
        case initializationError
        case compressionError
    }

    private var temporaryDirectory: URL {
        fileManager.temporaryDirectory.appendingPathComponent("org.giginet.ScipioS3Storage")
    }

    private var keySet: ArchiveHeader.FieldKeySet? {
        ArchiveHeader.FieldKeySet("TYP,PAT,LNK,DEV,DAT,UID,GID,MOD,FLG,MTM,BTM,CTM")
    }
}
