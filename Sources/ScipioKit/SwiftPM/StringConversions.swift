/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

/// Check if the given code unit needs shell escaping.
//
/// - Parameters:
///     - codeUnit: The code unit to be checked.
///
/// - Returns: True if shell escaping is not needed.
private func inShellAllowlist(_ codeUnit: UInt8) -> Bool {
  #if os(Windows)
    if codeUnit == UInt8(ascii: "\\") {
        return true
    }
  #endif
    switch codeUnit {
        case UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"),
             UInt8(ascii: "_"),
             UInt8(ascii: "/"),
             UInt8(ascii: ":"),
             UInt8(ascii: "@"),
             UInt8(ascii: "%"),
             UInt8(ascii: "+"),
             UInt8(ascii: "="),
             UInt8(ascii: "."),
             UInt8(ascii: ","):
        return true
    default:
        return false
    }
}

extension String {

    /// Creates a shell escaped string. If the string does not need escaping, returns the original string.
    /// Otherwise escapes using single quotes on Unix and double quotes on Windows. For example:
    /// hello -> hello, hello$world -> 'hello$world', input A -> 'input A'
    ///
    /// - Returns: Shell escaped string.
    func spm_shellEscaped() -> String {

        // If all the characters in the string are in the allow list then no need to escape.
        guard let pos = utf8.firstIndex(where: { !inShellAllowlist($0) }) else {
            return self
        }

#if os(Windows)
        let quoteCharacter: Character = "\""
        let escapedQuoteCharacter = "\"\""
#else
        let quoteCharacter: Character = "'"
        let escapedQuoteCharacter = "'\\''"
#endif
        // If there are no quote characters then we can just wrap the string within the quotes.
        guard let quotePos = utf8[pos...].firstIndex(of: quoteCharacter.asciiValue!) else {
            return String(quoteCharacter) + self + String(quoteCharacter)
        }

        // Otherwise iterate and escape all the single quotes.
        var newString = String(quoteCharacter) + String(self[..<quotePos])

        for char in self[quotePos...] {
            if char == quoteCharacter {
                newString += escapedQuoteCharacter
            } else {
                newString += String(char)
            }
        }

        newString += String(quoteCharacter)

        return newString
    }
}

extension String {
    /**
     Remove trailing newline characters. By default chomp removes
     all trailing \n (UNIX) or all trailing \r\n (Windows) (it will
     not remove mixed occurrences of both separators.
    */
    func spm_chomp(separator: String? = nil) -> String {
        func scrub(_ separator: String) -> String {
            var E = endIndex
            while String(self[startIndex..<E]).hasSuffix(separator) && E > startIndex {
                E = index(before: E)
            }
            return String(self[startIndex..<E])
        }

        if let separator = separator {
            return scrub(separator)
        } else if hasSuffix("\r\n") {
            return scrub("\r\n")
        } else if hasSuffix("\n") {
            return scrub("\n")
        } else {
            return self
        }
    }
}
