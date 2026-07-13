import Foundation
import ScipioKitCore

/// Rewrites angle-bracket C header includes into framework-relative form.
///
/// C packages address their own and their dependencies' public headers relative to the include
/// directory, e.g. `#include <core/core.h>`, and SwiftPM builds resolve that form through the
/// `-I` / `HEADER_SEARCH_PATHS` entries they inject. Consumers of the prebuilt XCFrameworks only
/// get `-F` (framework search), which answers `<ModuleName/...>`, so such includes no longer
/// resolve. While copying a module's public headers into its framework, we rewrite includes that
/// point at that module or one of its visible dependencies from `<core/core.h>` to
/// `<CoreLib/core/core.h>`. Consumers then need no extra wiring.
///
/// The rewrite target is the header's path **as it actually lands inside the owning framework**,
/// which depends on that module's `keepPublicHeadersStructure`: with it on, the nested layout
/// (`core/core.h`) is preserved; with it off, headers are flattened to their file name (`core.h`).
/// The replacement therefore encodes that final path, not the original source-relative path.
struct CHeaderIncludeRewriter {
    /// Source include path to framework include path, e.g. `"core/core.h" -> "CoreLib/core/core.h"`.
    private let replacementsByHeaderPath: [String: String]
    private let fileSystem: any FileSystem

    init(replacementsByHeaderPath: [String: String], fileSystem: some FileSystem = LocalFileSystem.default) {
        self.replacementsByHeaderPath = replacementsByHeaderPath
        self.fileSystem = fileSystem
    }

    /// Builds the table from a target and its visible dependency closure.
    init(
        modules: some Sequence<ResolvedModule>,
        keepPublicHeadersStructure: (ResolvedModule) -> Bool,
        fileSystem: some FileSystem = LocalFileSystem.default
    ) {
        var table: [String: String] = [:]
        var ambiguousPaths: Set<String> = []

        for module in modules {
            guard case let .clang(includeDir, publicHeaders) = module.resolvedModuleType else {
                continue
            }
            // `-F` resolves the framework bundle name, not the C99 modulemap name.
            let moduleName = module.name.packageNamed()
            let keepsStructure = keepPublicHeadersStructure(module)
            var base = includeDir.standardizedFileURL.path(percentEncoded: false)
            if base.hasSuffix("/") && base != "/" {
                base.removeLast()
            }

            for header in publicHeaders {
                let headerPath = header.standardizedFileURL.path(percentEncoded: false)
                guard headerPath.hasPrefix(base + "/") else { continue }
                let sourceRelativePath = String(headerPath.dropFirst(base.count + 1))
                guard !sourceRelativePath.isEmpty else { continue }

                // Includes use the symlink path; copied headers land at the resolved path.
                let landedHeader = fileSystem.isSymlink(header) ? header.resolvingSymlinksInPath() : header
                let inFrameworkPath = FrameworkBundleAssembler.headerDestinationComponents(
                    header: landedHeader,
                    includeDir: includeDir,
                    keepPublicHeadersStructure: keepsStructure
                ).joined(separator: "/")
                let replacement = "\(moduleName)/\(inFrameworkPath)"

                if let existing = table[sourceRelativePath], existing != replacement {
                    // Do not guess when two modules provide the same include path.
                    ambiguousPaths.insert(sourceRelativePath)
                    logger.warning(
                        "⚠️ Public header \(sourceRelativePath) is provided by multiple modules; leaving its includes unrewritten",
                        metadata: .color(.yellow)
                    )
                } else {
                    table[sourceRelativePath] = replacement
                }
            }
        }

        for path in ambiguousPaths {
            table[path] = nil
        }
        self.replacementsByHeaderPath = table
        self.fileSystem = fileSystem
    }

    var isEmpty: Bool { replacementsByHeaderPath.isEmpty }

    /// Where the header being rewritten comes from and how it lands inside the framework,
    /// so quoted includes can be checked against the copied layout.
    struct IncluderContext {
        var sourceFile: URL
        var includeDir: URL?
        var keepsPublicHeadersStructure: Bool
    }

    /// Leaves system, ambiguous, and out-of-closure includes unchanged.
    ///
    /// Quoted includes mirror the compiler's lookup order: a file reachable relative to the
    /// including header wins, but only as long as the copy into the framework preserves that
    /// relation; flattened layouts break subdirectory relations, so such includes are rewritten
    /// to the framework form like an angle include, looked up by the candidate's canonical
    /// include-dir-relative path so `./` and `../` spellings rewrite too.
    func rewrite(_ contents: String, includer: IncluderContext? = nil) -> String {
        guard !replacementsByHeaderPath.isEmpty else { return contents }

        let regex = /^(?<directive>\s*#\s*(?:include|import)\s*)(?:<(?<anglePath>[^>]+)>|"(?<quotedPath>[^"]+)")/

        let lines = contents.components(separatedBy: "\n")
        let rewritten = lines.map { line -> String in
            guard let match = line.firstMatch(of: regex) else {
                return line
            }

            let pathSubstring: Substring
            let isQuoted: Bool
            if let anglePath = match.output.anglePath {
                pathSubstring = anglePath
                isQuoted = false
            } else if let quotedPath = match.output.quotedPath {
                pathSubstring = quotedPath
                isQuoted = true
            } else {
                return line
            }

            let path = String(pathSubstring)
            let replacement: String?
            if isQuoted, let includer {
                replacement = quotedIncludeReplacement(for: path, from: includer)
            } else {
                replacement = searchPathReplacement(for: path)
            }
            guard let replacement else {
                return line
            }

            // Skip the original closing `>` or `"`; both are a single character.
            let trailing = line[line.index(after: pathSubstring.endIndex)...]
            return "\(match.output.directive)<\(replacement)>\(trailing)"
        }
        return rewritten.joined(separator: "\n")
    }

    /// Decides the framework path a quoted include is rewritten to; nil keeps the line.
    ///
    /// A candidate reachable relative to the including header wins the compiler's quoted lookup:
    /// it stays untouched while the copy preserves that relation, and is otherwise rewritten via
    /// the candidate's canonical include-dir-relative path, which also covers `./` and `../`
    /// spellings. An include with no relative candidate could only have resolved through the
    /// search paths, so it is looked up as written.
    private func quotedIncludeReplacement(for path: String, from includer: IncluderContext) -> String? {
        let candidate = includer.sourceFile.deletingLastPathComponent()
            .appending(path: path)
            .standardizedFileURL
        guard fileSystem.exists(candidate) else {
            return searchPathReplacement(for: path)
        }

        // A candidate outside the include dir is never copied; rewriting to some other module's
        // same-named header would silently change which contents get included.
        guard let base = includer.includeDir.map(Self.trimmedBasePath(of:)),
              candidate.path(percentEncoded: false).hasPrefix(base + "/") else {
            return nil
        }

        if quotedIncludeResolvesAfterCopy(path, candidate: candidate, from: includer) {
            return nil
        }

        let canonicalKey = String(candidate.path(percentEncoded: false).dropFirst(base.count + 1))
        return replacementsByHeaderPath[canonicalKey]
    }

    /// Whether a quoted include keeps resolving relative to its includer after both land in the
    /// framework: the candidate must land at the offset the include names, with `.` and `..`
    /// segments folded; escaping the framework's header root can never resolve.
    private func quotedIncludeResolvesAfterCopy(_ path: String, candidate: URL, from includer: IncluderContext) -> Bool {
        let includerDestination = FrameworkBundleAssembler.headerDestinationComponents(
            header: includer.sourceFile,
            includeDir: includer.includeDir,
            keepPublicHeadersStructure: includer.keepsPublicHeadersStructure
        )
        // Includes use the symlink path; copied headers land at the resolved path, and symlinks
        // duplicating a real header are not copied at all, so their landed path never matches.
        let landedCandidate = fileSystem.isSymlink(candidate) ? candidate.resolvingSymlinksInPath() : candidate
        let candidateDestination = FrameworkBundleAssembler.headerDestinationComponents(
            header: landedCandidate,
            includeDir: includer.includeDir,
            keepPublicHeadersStructure: includer.keepsPublicHeadersStructure
        )
        let named = includerDestination.dropLast() + path.split(separator: "/").map(String.init)
        guard let resolved = Self.foldingDotSegments(named) else {
            return false
        }
        return resolved == candidateDestination
    }

    /// Table lookup for an include that resolves through the search paths: each root interprets
    /// the path relative to itself, so the canonical table key has `.`/`..` segments folded.
    /// Absolute paths never resolve through the table.
    private func searchPathReplacement(for path: String) -> String? {
        guard !path.hasPrefix("/") else { return nil }
        guard let key = Self.foldingDotSegments(path.split(separator: "/").map(String.init)) else {
            return nil
        }
        return replacementsByHeaderPath[key.joined(separator: "/")]
    }

    private static func trimmedBasePath(of directory: URL) -> String {
        var base = directory.standardizedFileURL.path(percentEncoded: false)
        if base.hasSuffix("/") && base != "/" {
            base.removeLast()
        }
        return base
    }

    /// Folds `.` and `..` path components; nil when `..` escapes the root.
    private static func foldingDotSegments(_ components: some Sequence<String>) -> [String]? {
        var result: [String] = []
        for component in components {
            switch component {
            case ".":
                continue
            case "..":
                guard result.popLast() != nil else { return nil }
            default:
                result.append(component)
            }
        }
        return result
    }
}
