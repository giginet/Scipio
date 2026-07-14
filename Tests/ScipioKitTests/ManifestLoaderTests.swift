import Foundation
import Testing
@testable @_spi(Internals) import ScipioKit

struct ManifestLoaderTests {
    // A minimal dump-package payload whose top-level `traits` is the SwiftPM 6.1
    // object form. PackageManifestKit models Manifest.traits as [String]?, so this
    // fails to decode unless ManifestLoader strips the field first.
    private static let manifestWithObjectFormTraits = """
    {
      "name": "MyFramework",
      "toolsVersion": { "_version": "6.1.0" },
      "dependencies": [],
      "products": [],
      "targets": [],
      "packageKind": { "root": ["/tmp/MyFramework"] },
      "traits": [
        { "name": "default", "enabledTraits": ["Foo"] },
        { "name": "Foo", "description": "bar", "enabledTraits": [] }
      ]
    }
    """

    // Same manifest without a `traits` key: exercises the strip no-op path.
    private static let manifestWithoutTraits = """
    {
      "name": "MyFramework",
      "toolsVersion": { "_version": "6.1.0" },
      "dependencies": [],
      "products": [],
      "targets": [],
      "packageKind": { "root": ["/tmp/MyFramework"] }
    }
    """

    @Test
    func decodesManifestDeclaringObjectFormTraits() async throws {
        let executor = StubbableExecutor { arguments in
            StubbableExecutorResult(arguments: arguments, success: Self.manifestWithObjectFormTraits)
        }
        let loader = ManifestLoader(executor: executor)

        let manifest = try await loader.loadManifest(for: URL(filePath: "/tmp/MyFramework"))

        #expect(manifest.name == "MyFramework")
    }

    @Test
    func decodesManifestWithoutTraits() async throws {
        let executor = StubbableExecutor { arguments in
            StubbableExecutorResult(arguments: arguments, success: Self.manifestWithoutTraits)
        }
        let loader = ManifestLoader(executor: executor)

        let manifest = try await loader.loadManifest(for: URL(filePath: "/tmp/MyFramework"))

        #expect(manifest.name == "MyFramework")
    }
}
