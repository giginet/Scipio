import Foundation
import Testing
@testable import PIFKit

struct MacroDependencyTests {
    @Test("Host cleanup preserves same-named runtime references", arguments: [
        (hostIsProduct: false, ownerIsProduct: false), (hostIsProduct: false, ownerIsProduct: true),
        (hostIsProduct: true, ownerIsProduct: false), (hostIsProduct: true, ownerIsProduct: true),
    ], ["", "@11"])
    func preservesSameNamedRuntimeReferences(scenario: (hostIsProduct: Bool, ownerIsProduct: Bool), suffix: String) throws {
        let (hostIsProduct, ownerIsProduct) = scenario
        let targetGUID = "PACKAGE-TARGET:Shared\(suffix)"
        let productGUID = "PACKAGE-PRODUCT:Shared\(suffix)"
        let pluginGUID = "PACKAGE-TARGET:Plugin\(suffix)"
        let otherTargetGUID = "PACKAGE-TARGET:SharedExtra\(suffix)"
        let otherProductGUID = "PACKAGE-PRODUCT:SharedExtra\(suffix)"
        let ownerName = ownerIsProduct ? "PublicClient_123_PackageProduct" : "Client"
        let ownerGUID = ownerIsProduct ? "PACKAGE-PRODUCT:PublicClient\(suffix)" : "PACKAGE-TARGET:Client\(suffix)"
        let input = """
        [
          {"type":"target","contents":{"name":"Shared","guid":"\(targetGUID)"}},
          {"type":"target","contents":{"name":"Shared_123_PackageProduct","guid":"\(productGUID)"}},
          {"type":"target","contents":{"name":"Plugin","guid":"\(pluginGUID)"}},
          {"type":"target","contents":{"name":"\(ownerName)","guid":"\(ownerGUID)",
            "dependencies":[{"guid":"\(targetGUID)"},{"guid":"\(productGUID)"},{"guid":"\(pluginGUID)"},
              {"guid":"\(otherTargetGUID)"},{"guid":"\(otherProductGUID)"}],
            "buildPhases":[{"buildFiles":[{"targetReference":"\(targetGUID)"},{"targetReference":"\(productGUID)"},
              {"targetReference":"\(pluginGUID)"},{"targetReference":"\(otherTargetGUID)"},{"targetReference":"\(otherProductGUID)"}]}]}}
        ]
        """
        let hostDependencies: Set<PIFDependency> = [.target("Plugin"), hostIsProduct ? .product("Shared") : .target("Shared")]
        let manipulator = try PIFManipulator(jsonData: Data(input.utf8))

        manipulator.removeHostMacroDependencies(
            ["Client": hostDependencies], productDependencies: ["PublicClient": hostDependencies]
        )

        let output = try JSONSerialization.jsonObject(with: manipulator.dump()) as? [[String: Any]]
        let owner = try #require(output?.last?["contents"] as? [String: Any])
        let dependencies = try #require(owner["dependencies"] as? [[String: Any]])
        let expected = [hostIsProduct ? targetGUID : productGUID, otherTargetGUID, otherProductGUID]
        #expect(dependencies.compactMap { $0["guid"] as? String } == expected)
        let phases = try #require(owner["buildPhases"] as? [[String: Any]])
        let buildFiles = try #require(phases.first?["buildFiles"] as? [[String: Any]])
        #expect(buildFiles.compactMap { $0["targetReference"] as? String } == expected)
    }

    @Test func removesOnlySelectedHostPluginEdges() throws {
        let input = """
        [
          {"type":"target","contents":{"name":"Plugin","guid":"plugin","productTypeIdentifier":"com.apple.product-type.tool.host-build"}},
          {"type":"target","contents":{"name":"Other","guid":"other","productTypeIdentifier":"com.apple.product-type.tool.host-build"}},
          {"type":"target","contents":{"name":"SwiftSyntax_123_PackageProduct","guid":"PACKAGE-PRODUCT:SwiftSyntax@11"}},
          {"type":"target","contents":{"name":"PublicDeclarations_123_PackageProduct","guid":"PACKAGE-PRODUCT:PublicDeclarations@11",
             "dependencies":[{"guid":"PACKAGE-PRODUCT:SwiftSyntax@11"},{"guid":"PACKAGE-TARGET:Plugin@11"},{"guid":"framework"}],
             "buildPhases":[{"buildFiles":[{"targetReference":"PACKAGE-PRODUCT:SwiftSyntax@11"},{"targetReference":"framework"}]}]}},
          {"type":"target","contents":{"name":"Library","guid":"library",
             "dependencies":[{"guid":"plugin"},{"guid":"PACKAGE-PRODUCT:SwiftSyntax@11"},{"guid":"other"},{"guid":"framework"}]}}
        ]
        """
        let manipulator = try PIFManipulator(jsonData: Data(input.utf8))
        manipulator.removeHostMacroDependencies(
            ["Library": [.target("Plugin"), .product("SwiftSyntax")]],
            productDependencies: ["PublicDeclarations": [.target("Plugin"), .product("SwiftSyntax")]]
        )
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
