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

    init(replacementsByHeaderPath: [String: String]) {
        self.replacementsByHeaderPath = replacementsByHeaderPath
    }

    /// Builds the table from a target and its visible dependency closure.
    init(
        modules: some Sequence<ResolvedModule>,
        keepPublicHeadersStructure: (ResolvedModule) -> Bool,
        fileSystem: any FileSystem = LocalFileSystem.default
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
                        "Public header \(sourceRelativePath) is provided by multiple modules; leaving its includes unrewritten"
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
    }

    var isEmpty: Bool { replacementsByHeaderPath.isEmpty }

    // Angle includes only; quoted includes keep their source-relative semantics.
    private static let includeRegex = try! NSRegularExpression(
        pattern: #"^(\s*#\s*(?:include|import)\s*)<([^>]+)>"#
    )

    /// Leaves system, ambiguous, and out-of-closure includes unchanged.
    func rewrite(_ contents: String) -> String {
        guard !replacementsByHeaderPath.isEmpty else { return contents }

        let lines = contents.components(separatedBy: "\n")
        let rewritten = lines.map { line -> String in
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = Self.includeRegex.firstMatch(in: line, range: range),
                  let directiveRange = Range(match.range(at: 1), in: line),
                  let pathRange = Range(match.range(at: 2), in: line) else {
                return line
            }

            let path = String(line[pathRange])
            guard let replacement = replacementsByHeaderPath[path] else {
                return line
            }

            let directive = line[directiveRange]
            let trailing = line[pathRange.upperBound...] // includes the closing `>` and any comment
            return "\(directive)<\(replacement)\(trailing)"
        }
        return rewritten.joined(separator: "\n")
    }
}
