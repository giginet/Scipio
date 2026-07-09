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

    @Test("Leaves unknown, quoted, and empty-table includes untouched")
    func leavesNonMatchingIncludesUntouched() {
        #expect(rewriter.rewrite("#include <stdio.h>") == "#include <stdio.h>")
        #expect(rewriter.rewrite("#include <other/unknown.h>") == "#include <other/unknown.h>")
        #expect(rewriter.rewrite("#include \"dep/foo.h\"") == "#include \"dep/foo.h\"")

        let empty = CHeaderIncludeRewriter(replacementsByHeaderPath: [:])
        #expect(empty.isEmpty)
        #expect(empty.rewrite("#include <dep/foo.h>") == "#include <dep/foo.h>")
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
