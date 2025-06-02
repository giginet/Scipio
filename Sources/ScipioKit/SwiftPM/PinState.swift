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

public enum SPMPinState: Equatable, Sendable, CustomStringConvertible {
    case branch(name: String, revision: String)
    case version(_ version: Version, revision: String?)
    case revision(_ revision: String)

    public var description: String {
        switch self {
        case .version(let version, _):
            return version.description
        case .branch(let name, _):
            return name
        case .revision(let revision):
            return revision
        }
    }
}

extension SPMPinState: Codable {
    enum Key: CodingKey {
        case revision
        case branch
        case version
    }

    public func encode(to encoder: Encoder) throws {
        var versionContainer = encoder.container(keyedBy: Key.self)
        switch self {
        case .version(let version, let revision):
            try versionContainer.encode(version.description, forKey: .version)
            try versionContainer.encode(revision, forKey: .revision)
        case .revision(let revision):
            try versionContainer.encode(revision, forKey: .revision)
        case .branch(let branchName, let revision):
            try versionContainer.encode(branchName, forKey: .branch)
            try versionContainer.encode(revision, forKey: .revision)
        }
    }

    public init(from decoder: Decoder) throws {
        let decoder = try decoder.container(keyedBy: Key.self)
        if decoder.contains(.branch) {
            let branchName = try decoder.decode(String.self, forKey: .branch)
            let revision = try decoder.decode(String.self, forKey: .revision)
            self = .branch(name: branchName, revision: revision)
        } else if decoder.contains(.version) {
            let version = try decoder.decode(Version.self, forKey: .version)
            let revision = try decoder.decode(String?.self, forKey: .revision)
            self = .version(version, revision: revision)
        } else {
            let revision = try decoder.decode(String.self, forKey: .revision)
            self = .revision(revision)
        }
    }
}

extension SPMPinState: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .revision(let revision):
            hasher.combine(revision)
        case .version(let version, let revision):
            hasher.combine(version)
            hasher.combine(revision)
        case .branch(let branchName, let revision):
            hasher.combine(branchName)
            hasher.combine(revision)
        }
    }
}
