import Darwin
import Foundation
import Testing
@testable import ScipioKit

struct ProcessOutputReaderTests {
    @Test("Reader finishes when the pipe reaches EOF")
    func finishesAtEOF() throws {
        let pipe = Pipe()
        let readHandle = pipe.fileHandleForReading
        let writeHandle = pipe.fileHandleForWriting
        let reader = ProcessOutputReader(fileHandle: readHandle)
        defer {
            reader.close()
            try? writeHandle.close()
        }

        try writeHandle.close()

        #expect(reader.drain() == .finished)
        #expect(reader.drain() == .finished)
    }

    @Test("Reader ignores stale drains after closing")
    func ignoresStaleDrainsAfterClosing() throws {
        let sourcePipe = Pipe()
        let sourceReadHandle = sourcePipe.fileHandleForReading
        let sourceWriteHandle = sourcePipe.fileHandleForWriting
        let reader = ProcessOutputReader(fileHandle: sourceReadHandle)
        defer {
            reader.close()
            try? sourceWriteHandle.close()
        }

        try setNonBlocking(sourceReadHandle.fileDescriptor)
        let expectedOutput = Array("captured-output".utf8)
        try sourceWriteHandle.write(contentsOf: Data(expectedOutput))

        #expect(reader.drain() == .continueReading)
        #expect(reader.snapshot == expectedOutput)

        reader.close()
        try sourceWriteHandle.close()

        // Represents a queued readability handler running after the original
        // descriptor has been closed and its numeric value may have been reused.
        let replacementPipe = Pipe()
        let replacementReadHandle = replacementPipe.fileHandleForReading
        let replacementWriteHandle = replacementPipe.fileHandleForWriting
        defer {
            try? replacementReadHandle.close()
            try? replacementWriteHandle.close()
        }

        try replacementWriteHandle.write(contentsOf: Data("unrelated-output".utf8))
        try replacementWriteHandle.close()

        #expect(reader.drain() == .finished)

        #expect(reader.snapshot == expectedOutput)
    }

    private func setNonBlocking(_ fileDescriptor: Int32) throws {
        let flags = fcntl(fileDescriptor, F_GETFL)
        try #require(flags != -1)
        try #require(fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) != -1)
    }
}
