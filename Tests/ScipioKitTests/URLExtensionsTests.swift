import Testing
import Foundation
@testable import ScipioKit

struct URLExtensionsTests {
    @Test("dirname returns the parent path component for given file paths", arguments: [
        ("/path/to/test.txt", "/path/to"),
        ("/test.txt", "/"),
        ("/", "/"),
        ("/path//to///test.txt", "/path/to"),
        ("/path/to/", "/path/to"),
        ("///multiple///slashes///test.txt", "/multiple/slashes"),
        ("/path/to/../..", "/"),
        ("/path/to/../test.txt", "/path"),
    ])
    func dirname(input: String, expected: String) {
        let url = URL(filePath: input)
        #expect(url.dirname == expected)
    }

    @Test("parentDirectory returns the parent directory URL for given file paths", arguments: [
        ("/path/to/test.txt", "/path/to"),
        ("/test.txt", "/"),
        ("/", "/"),
        ("/path//to///test.txt", "/path/to"),
        ("/path/to/", "/path/to"),
        ("///multiple///slashes///test.txt", "/multiple/slashes"),
        ("/path/to/../..", "/"),
        ("/path/to/../test.txt", "/path"),
    ])
    func parentDirectory(input: String, expectedPath: String) {
        let url = URL(filePath: input)
        let expected = URL(filePath: expectedPath)
        #expect(url.parentDirectory == expected)
    }
}
