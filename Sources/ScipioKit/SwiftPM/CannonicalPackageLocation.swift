// ===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
// ===----------------------------------------------------------------------===//
//
// NOTE: This file has been modified from the original version.
//
// ===----------------------------------------------------------------------===//

import Foundation

struct CanonicalPackageLocation: Equatable, CustomStringConvertible {
    /// A textual representation of this instance.
    let description: String

    /// Instantiates an instance of the conforming type from a string representation.
    init(_ string: String) {
        self.description = computeCanonicalLocation(string).description
    }
}

/// Similar to `CanonicalPackageLocation` but differentiates based on the scheme.
struct CanonicalPackageURL: Equatable, CustomStringConvertible {
    let description: String
    let scheme: String?

    init(_ string: String) {
        let location = computeCanonicalLocation(string)
        self.description = location.description
        self.scheme = location.scheme
    }
}

private func computeCanonicalLocation(_ string: String) -> (description: String, scheme: String?) {
    var description = string.precomposedStringWithCanonicalMapping.lowercased()

    // Remove the scheme component, if present.
    let detectedScheme = description.dropSchemeComponentPrefixIfPresent()
    var scheme = detectedScheme

    // Remove the userinfo subcomponent (user / password), if present.
    if case (let user, _)? = description.dropUserinfoSubcomponentPrefixIfPresent() {
        // If a user was provided, perform tilde expansion, if applicable.
        description.replaceFirstOccurrenceIfPresent(of: "/~/", with: "/~\(user)/")

        if user == "git", scheme == nil {
            scheme = "ssh"
        }
    }

    // Remove the port subcomponent, if present.
    description.removePortComponentIfPresent()

    // Remove the fragment component, if present.
    description.removeFragmentComponentIfPresent()

    // Remove the query component, if present.
    description.removeQueryComponentIfPresent()

    // Accommodate "`scp`-style" SSH URLs
    if detectedScheme == nil || detectedScheme == "ssh" {
        description.replaceFirstOccurrenceIfPresent(of: ":", before: description.firstIndex(of: "/"), with: "/")
    }

    // Split the remaining string into path components,
    // filtering out empty path components and removing valid percent encodings.
    var components = description.split(omittingEmptySubsequences: true, whereSeparator: isSeparator)
        .compactMap { $0.removingPercentEncoding ?? String($0) }

    // Remove the `.git` suffix from the last path component.
    var lastPathComponent = components.popLast() ?? ""
    lastPathComponent.removeSuffixIfPresent(".git")
    components.append(lastPathComponent)

    description = components.joined(separator: "/")

    // Prepend a leading slash for file URLs and paths
    if detectedScheme == "file" || string.first.flatMap(isSeparator) ?? false {
        scheme = "file"
        description.insert("/", at: description.startIndex)
    }

    return (description, scheme)
}

nonisolated(unsafe) private let isSeparator: (Character) -> Bool = { $0 == "/" }

extension Character {
    fileprivate var isDigit: Bool {
        switch self {
        case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
            return true
        default:
            return false
        }
    }

    fileprivate var isAllowedInURLScheme: Bool {
        isLetter || self.isDigit || self == "+" || self == "-" || self == "."
    }
}

extension String {
    @discardableResult
    private mutating func removePrefixIfPresent<T: StringProtocol>(_ prefix: T) -> Bool {
        guard hasPrefix(prefix) else { return false }
        removeFirst(prefix.count)
        return true
    }

    @discardableResult
    fileprivate mutating func removeSuffixIfPresent<T: StringProtocol>(_ suffix: T) -> Bool {
        guard hasSuffix(suffix) else { return false }
        removeLast(suffix.count)
        return true
    }

    @discardableResult
    fileprivate mutating func dropSchemeComponentPrefixIfPresent() -> String? {
        if let rangeOfDelimiter = range(of: "://"),
           self[startIndex].isLetter,
           self[..<rangeOfDelimiter.lowerBound].allSatisfy(\.isAllowedInURLScheme) {
            defer { self.removeSubrange(..<rangeOfDelimiter.upperBound) }

            return String(self[..<rangeOfDelimiter.lowerBound])
        }

        return nil
    }

    @discardableResult
    fileprivate mutating func dropUserinfoSubcomponentPrefixIfPresent() -> (user: String, password: String?)? {
        if let indexOfAtSign = firstIndex(of: "@"),
           let indexOfFirstPathComponent = firstIndex(where: isSeparator),
           indexOfAtSign < indexOfFirstPathComponent {
            defer { self.removeSubrange(...indexOfAtSign) }

            let userinfo = self[..<indexOfAtSign]
            var components = userinfo.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard components.count > 0 else { return nil }
            let user = String(components.removeFirst())
            let password = components.last.map(String.init)

            return (user, password)
        }

        return nil
    }

    @discardableResult
    fileprivate mutating func removePortComponentIfPresent() -> Bool {
        if let indexOfFirstPathComponent = firstIndex(where: isSeparator),
           let startIndexOfPort = firstIndex(of: ":"),
           startIndexOfPort < endIndex,
           let endIndexOfPort = self[index(after: startIndexOfPort)...].lastIndex(where: { $0.isDigit }),
           endIndexOfPort <= indexOfFirstPathComponent {
            self.removeSubrange(startIndexOfPort ... endIndexOfPort)
            return true
        }

        return false
    }

    @discardableResult
    fileprivate mutating func removeFragmentComponentIfPresent() -> Bool {
        if let index = firstIndex(of: "#") {
            self.removeSubrange(index...)
        }

        return false
    }

    @discardableResult
    fileprivate mutating func removeQueryComponentIfPresent() -> Bool {
        if let index = firstIndex(of: "?") {
            self.removeSubrange(index...)
        }

        return false
    }

    @discardableResult
    fileprivate mutating func replaceFirstOccurrenceIfPresent<T: StringProtocol, U: StringProtocol>(
        of string: T,
        before index: Index? = nil,
        with replacement: U
    ) -> Bool {
        guard let range = range(of: string) else { return false }

        if let index, range.lowerBound >= index {
            return false
        }

        self.replaceSubrange(range, with: replacement)
        return true
    }
}
