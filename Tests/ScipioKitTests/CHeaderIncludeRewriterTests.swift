import Foundation
import Testing
@testable import ScipioKit

private let fixturePath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources")
    .appendingPathComponent("Fixtures")

struct CHeaderIncludeRewriterTests {
    private let rewriter = CHeaderIncludeRewriter(
        replacementsByHeaderPath: [
            "dep/foo.h": "DepModule/dep/foo.h",
            "core/nested/types.h": "CoreLib/core/nested/types.h",
        ]
    )

    @Test("Rewrites include and import directives to framework form")
    func rewritesAngleBracketIncludesToFrameworkForm() {
        #expect(rewriter.rewrite("#include <dep/foo.h>") == "#include <DepModule/dep/foo.h>")
        #expect(rewriter.rewrite("#import <dep/foo.h>") == "#import <DepModule/dep/foo.h>")
        #expect(rewriter.rewrite("#include <core/nested/types.h>") == "#include <CoreLib/core/nested/types.h>")
        let spacedInclude = "  #  include   <dep/foo.h> // keep me"
        #expect(rewriter.rewrite(spacedInclude) == "  #  include   <DepModule/dep/foo.h> // keep me")
        #expect(rewriter.rewrite("#include<dep/foo.h>") == "#include<DepModule/dep/foo.h>")
    }

    @Test("Leaves unknown and empty-table includes untouched")
    func leavesNonMatchingIncludesUntouched() {
        #expect(rewriter.rewrite("#include <stdio.h>") == "#include <stdio.h>")
        #expect(rewriter.rewrite("#include <other/unknown.h>") == "#include <other/unknown.h>")
        #expect(rewriter.rewrite("#include \"other/unknown.h\"") == "#include \"other/unknown.h\"")

        let empty = CHeaderIncludeRewriter(replacementsByHeaderPath: [:])
        #expect(empty.isEmpty)
        #expect(empty.rewrite("#include <dep/foo.h>") == "#include <dep/foo.h>")
    }

    @Test("Quoted includes rewrite unless the copied layout still resolves them")
    func rewritesQuotedIncludesAgainstCopiedLayout() throws {
        // Without an includer the search-path fallback is the only possible resolution.
        #expect(rewriter.rewrite("#include \"dep/foo.h\"") == "#include <DepModule/dep/foo.h>")
        #expect(rewriter.rewrite("#import \"dep/foo.h\" // keep me") == "#import <DepModule/dep/foo.h> // keep me")

        let includeDir = FileManager.default.temporaryDirectory
            .appending(components: "CHeaderIncludeRewriterTests", UUID().uuidString, "include")
        defer { try? FileManager.default.removeItem(at: includeDir.deletingLastPathComponent()) }
        let includer = includeDir.appending(component: "root.h")
        let sibling = includeDir.appending(component: "sibling.h")
        let nested = includeDir.appending(components: "dep", "foo.h")
        try FileManager.default.createDirectory(
            at: nested.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        for file in [includer, sibling, nested] {
            try Data().write(to: file)
        }

        // With the structure kept, the relative relation survives the copy and the include stays.
        let keepingStructure = CHeaderIncludeRewriter.IncluderContext(
            sourceFile: includer,
            includeDir: includeDir,
            keepsPublicHeadersStructure: true
        )
        #expect(
            rewriter.rewrite("#include \"dep/foo.h\"", includer: keepingStructure) ==
            "#include \"dep/foo.h\""
        )

        // Flattening moves the candidate next to the includer, breaking the subdirectory
        // relation: the include must be rewritten to the framework form.
        let flattening = CHeaderIncludeRewriter.IncluderContext(
            sourceFile: includer,
            includeDir: includeDir,
            keepsPublicHeadersStructure: false
        )
        #expect(
            rewriter.rewrite("#include \"dep/foo.h\"", includer: flattening) ==
            "#include <DepModule/dep/foo.h>"
        )

        // A bare sibling stays next to the includer in both layouts and survives flattening.
        let siblingRewriter = CHeaderIncludeRewriter(
            replacementsByHeaderPath: ["sibling.h": "DepModule/sibling.h"]
        )
        #expect(
            siblingRewriter.rewrite("#include \"sibling.h\"", includer: flattening) ==
            "#include \"sibling.h\""
        )

        // With no relative candidate on disk, only the search paths could have resolved it.
        let outside = CHeaderIncludeRewriter.IncluderContext(
            sourceFile: includeDir.appending(components: "dep", "other.h"),
            includeDir: includeDir,
            keepsPublicHeadersStructure: true
        )
        #expect(
            rewriter.rewrite("#include \"dep/foo.h\"", includer: outside) ==
            "#include <DepModule/dep/foo.h>"
        )

        // A symlinked candidate lands at its resolved path (or, duplicating a real header, is
        // not copied at all), so the include must be rewritten to the table's landed path.
        let linkedCandidate = includeDir.appending(component: "link.h")
        try FileManager.default.createSymbolicLink(at: linkedCandidate, withDestinationURL: sibling)
        let symlinkRewriter = CHeaderIncludeRewriter(
            replacementsByHeaderPath: ["link.h": "DepModule/sibling.h"]
        )
        #expect(
            symlinkRewriter.rewrite("#include \"link.h\"", includer: flattening) ==
            "#include <DepModule/sibling.h>"
        )
    }

    @Test("Dot-segment quoted includes rewrite via the candidate's canonical path")
    func rewritesDotSegmentQuotedIncludes() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(components: "CHeaderIncludeRewriterTests", UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let includeDir = root.appending(component: "include")
        let includer = includeDir.appending(components: "sub", "root.h")
        let candidate = includeDir.appending(component: "foo.h")
        let escapee = root.appending(component: "escape.h")
        try FileManager.default.createDirectory(
            at: includer.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        for file in [includer, candidate, escapee] {
            try Data().write(to: file)
        }
        let dotRewriter = CHeaderIncludeRewriter(
            replacementsByHeaderPath: ["foo.h": "DepModule/foo.h"]
        )

        // Flattening breaks the `..` relation; the canonical key "foo.h" finds the landed path.
        let flattening = CHeaderIncludeRewriter.IncluderContext(
            sourceFile: includer,
            includeDir: includeDir,
            keepsPublicHeadersStructure: false
        )
        #expect(
            dotRewriter.rewrite("#include \"../foo.h\"", includer: flattening) ==
            "#include <DepModule/foo.h>"
        )

        // With the structure kept, `../foo.h` still resolves inside Headers/ and stays.
        let keepingStructure = CHeaderIncludeRewriter.IncluderContext(
            sourceFile: includer,
            includeDir: includeDir,
            keepsPublicHeadersStructure: true
        )
        #expect(
            dotRewriter.rewrite("#include \"../foo.h\"", includer: keepingStructure) ==
            "#include \"../foo.h\""
        )

        // A candidate escaping the include dir is never copied: rewriting cannot help.
        #expect(
            dotRewriter.rewrite("#include \"../../escape.h\"", includer: keepingStructure) ==
            "#include \"../../escape.h\""
        )

        // No includer-relative candidate: the search paths fold dot segments while resolving,
        // so the canonical key must be used for the table lookup as well.
        #expect(
            dotRewriter.rewrite("#include \"./foo.h\"", includer: keepingStructure) ==
            "#include <DepModule/foo.h>"
        )
        #expect(rewriter.rewrite("#include \"./dep/foo.h\"") == "#include <DepModule/dep/foo.h>")
        #expect(rewriter.rewrite("#include <./dep/foo.h>") == "#include <DepModule/dep/foo.h>")

        // Absolute includes never resolve through the search paths' relative roots.
        #expect(rewriter.rewrite("#include \"/dep/foo.h\"") == "#include \"/dep/foo.h\"")
    }

    @Test("Only matching lines change while preserving line endings")
    func rewritesOnlyMatchingLinesPreservingOtherContents() {
        let input = """
        #include <dep/foo.h>
        #include <stdio.h>
        int answer(void) { return 42; }
        #include "relative.h"
        """
        let expected = """
        #include <DepModule/dep/foo.h>
        #include <stdio.h>
        int answer(void) { return 42; }
        #include "relative.h"
        """
        #expect(rewriter.rewrite(input) == expected)
        let crlfInput = "#include <dep/foo.h>\r\nint x;\r\n"
        #expect(rewriter.rewrite(crlfInput) == "#include <DepModule/dep/foo.h>\r\nint x;\r\n")
    }

    @Test("Replacement uses the header layout produced in the framework")
    func buildsReplacementFromModuleHeaderLayout() async throws {
        let package = try await DescriptionPackage(
            packageDirectory: fixturePath.appendingPathComponent("ClangPackageWithInterdependentHeaders"),
            mode: .createPackage,
            resolvedPackagesCachePolicies: [],
            onlyUseVersionsFromResolvedFile: false
        )
        let coreLib = try #require(package.graph.allModules.first { $0.name == "CoreLib" })

        let keepingStructure = CHeaderIncludeRewriter(modules: [coreLib], keepPublicHeadersStructure: { _ in true })
        #expect(keepingStructure.rewrite("#include <core/core.h>") == "#include <CoreLib/core/core.h>")

        let flattening = CHeaderIncludeRewriter(modules: [coreLib], keepPublicHeadersStructure: { _ in false })
        #expect(flattening.rewrite("#include <core/core.h>") == "#include <CoreLib/core.h>")
    }

    @Test("Ambiguous header paths are left unrewritten")
    func leavesAmbiguousHeaderPathsUnrewritten() async throws {
        let package = try await DescriptionPackage(
            packageDirectory: fixturePath.appendingPathComponent("ClangPackageWithConflictingHeaders"),
            mode: .createPackage,
            resolvedPackagesCachePolicies: [],
            onlyUseVersionsFromResolvedFile: false
        )
        let consumer = try #require(package.graph.allModules.first { $0.name == "Consumer" })
        let closure = try [consumer] + consumer.recursiveModuleDependencies()

        let rewriter = CHeaderIncludeRewriter(modules: closure, keepPublicHeadersStructure: { _ in false })

        #expect(rewriter.rewrite("#include <shared.h>") == "#include <shared.h>")
        #expect(rewriter.rewrite("#include <consumer.h>") == "#include <Consumer/consumer.h>")
    }

    @Test("Symlinked headers rewrite to their landed framework path")
    func resolvesSymlinkedHeadersToTheirLandedPath() async throws {
        let package = try await DescriptionPackage(
            packageDirectory: fixturePath.appendingPathComponent("ClangPackageWithSymbolicLinkHeaders"),
            mode: .createPackage,
            resolvedPackagesCachePolicies: [],
            onlyUseVersionsFromResolvedFile: false
        )
        let someLib = try #require(package.graph.allModules.first { $0.name == "some_lib" })

        let rewriter = CHeaderIncludeRewriter(modules: [someLib], keepPublicHeadersStructure: { _ in true })

        // The collector deduplicates this symlink against its real header.
        #expect(rewriter.rewrite("#include <some_lib_dupe.h>") == "#include <some_lib/some_lib.h>")
        #expect(rewriter.rewrite("#include <a.h>") == "#include <some_lib/a.h>")
        #expect(rewriter.rewrite("#include <some_lib.h>") == "#include <some_lib/some_lib.h>")
    }
}
