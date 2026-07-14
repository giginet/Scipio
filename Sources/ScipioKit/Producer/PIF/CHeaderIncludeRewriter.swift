import Foundation
import ScipioKitCore

/// Rewrites C header includes resolved through SwiftPM header search paths into framework form.
///
/// SwiftPM packages commonly include public headers as `<core/core.h>` and rely on injected
/// `-I` / `HEADER_SEARCH_PATHS`. Prebuilt framework consumers only get `-F`, which resolves
/// `<ModuleName/...>`, so copied headers need framework-relative includes.
///
/// Replacement paths match where headers land in their framework, including flattened layouts.
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

    /// Source and copy-layout context for quoted include resolution.
    struct IncluderContext {
        var sourceFile: URL
        var includeDir: URL?
        var keepsPublicHeadersStructure: Bool
    }

    /// Leaves system, ambiguous, and out-of-closure includes unchanged.
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

            let trailing = line[line.index(after: pathSubstring.endIndex)...]
            return "\(match.output.directive)<\(replacement)>\(trailing)"
        }
        return rewritten.joined(separator: "\n")
    }

    /// Returns the framework include path for a quoted include, or nil when it should stay quoted.
    ///
    /// Quoted includes first try the includer's directory. They stay quoted only if that same
    /// relation still exists after the headers are copied into the framework; otherwise they are
    /// rewritten through the candidate's canonical include-dir-relative path.
    private func quotedIncludeReplacement(for path: String, from includer: IncluderContext) -> String? {
        let candidate = includer.sourceFile.deletingLastPathComponent()
            .appending(path: path)
            .standardizedFileURL
        guard fileSystem.exists(candidate) else {
            return searchPathReplacement(for: path)
        }

        // Do not replace a private relative include with a public header that merely shares a name.
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

    /// Whether the quoted path still reaches the same candidate in the copied framework layout.
    private func quotedIncludeResolvesAfterCopy(_ path: String, candidate: URL, from includer: IncluderContext) -> Bool {
        let includerDestination = FrameworkBundleAssembler.headerDestinationComponents(
            header: includer.sourceFile,
            includeDir: includer.includeDir,
            keepPublicHeadersStructure: includer.keepsPublicHeadersStructure
        )
        // Copied headers land at resolved symlink paths.
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

    /// Table lookup for an include resolved relative to a header search path root.
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
