import Foundation
import Testing
@testable import PIFKit

struct MacroDependencyTests {
    @Test func removesOnlySelectedHostPluginEdges() throws {
        let input = """
        [
          {"type":"target","contents":{"name":"Plugin","guid":"plugin","productTypeIdentifier":"com.apple.product-type.tool.host-build"}},
          {"type":"target","contents":{"name":"Other","guid":"other","productTypeIdentifier":"com.apple.product-type.tool.host-build"}},
          {"type":"target","contents":{"name":"SwiftSyntax_123_PackageProduct","guid":"syntax-product"}},
          {"type":"target","contents":{"name":"Library_123_PackageProduct","guid":"library-product",
             "dependencies":[{"guid":"syntax-product"},{"guid":"PACKAGE-TARGET:Plugin@11"},{"guid":"framework"}],
             "buildPhases":[{"buildFiles":[{"targetReference":"syntax-product"},{"targetReference":"framework"}]}]}},
          {"type":"target","contents":{"name":"Library","guid":"library",
             "dependencies":[{"guid":"plugin"},{"guid":"syntax-product"},{"guid":"other"},{"guid":"framework"}]}}
        ]
        """
        let manipulator = try PIFManipulator(jsonData: Data(input.utf8))
        manipulator.removeHostMacroDependencies(["Library": ["Plugin", "SwiftSyntax"]])
        let output = try JSONSerialization.jsonObject(with: manipulator.dump()) as? [[String: Any]]
        let library = try #require(output?.last?["contents"] as? [String: Any])
        let dependencies = try #require(library["dependencies"] as? [[String: Any]])
        #expect(dependencies.compactMap { $0["guid"] as? String } == ["other", "framework"])
        let product = try #require(output?[3]["contents"] as? [String: Any])
        let productDependencies = try #require(product["dependencies"] as? [[String: Any]])
        #expect(productDependencies.compactMap { $0["guid"] as? String } == ["framework"])
        let phases = try #require(product["buildPhases"] as? [[String: Any]])
        let buildFiles = try #require(phases.first?["buildFiles"] as? [[String: Any]])
        #expect(buildFiles.compactMap { $0["targetReference"] as? String } == ["framework"])
    }
}
