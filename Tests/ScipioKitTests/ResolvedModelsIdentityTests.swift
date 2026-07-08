import Foundation
import PackageManifestKit
import Testing
@testable import ScipioKitCore

struct ResolvedModelsIdentityTests {
    @Test("Module equality and hashing are identity-based")
    func moduleEqualityIsIdentityBased() throws {
        let plain = try ResolvedGraphFixtures.module(name: "MyModule")
        let dependency = try ResolvedGraphFixtures.module(name: "Dependency")
        let richer = try ResolvedGraphFixtures.module(
            name: "MyModule",
            dependencies: [.module(dependency, conditions: [])],
            resolvedModuleType: .clang(includeDir: URL(filePath: "/tmp/include"), publicHeaders: [])
        )
        let otherPackage = try ResolvedGraphFixtures.module(
            name: "MyModule",
            packageID: ResolvedGraphFixtures.packageID("other-package")
        )

        #expect(plain == richer)
        #expect(plain.hashValue == richer.hashValue)
        #expect(plain != dependency)
        #expect(plain != otherPackage)
    }

    @Test("Product equality and hashing are identity-based")
    func productEqualityIsIdentityBased() throws {
        let module = try ResolvedGraphFixtures.module(name: "MyModule")
        let empty = try ResolvedGraphFixtures.resolvedProduct(name: "MyProduct", modules: [])
        let richer = try ResolvedGraphFixtures.resolvedProduct(name: "MyProduct", modules: [module])
        let differentName = try ResolvedGraphFixtures.resolvedProduct(name: "OtherProduct", modules: [])
        let differentPackage = try ResolvedGraphFixtures.resolvedProduct(
            name: "MyProduct",
            modules: [],
            packageID: ResolvedGraphFixtures.packageID("other-package")
        )

        #expect(empty == richer)
        #expect(empty.hashValue == richer.hashValue)
        #expect(empty != differentName)
        #expect(empty != differentPackage)
    }

    @Test("Module dependencies still distinguish their conditions")
    func dependencyEqualityDistinguishesConditions() throws {
        let module = try ResolvedGraphFixtures.module(name: "MyModule")
        let unconditional = ResolvedModule.Dependency.module(module, conditions: [])
        let conditional = ResolvedModule.Dependency.module(
            module,
            conditions: [PackageCondition(platformNames: ["ios"], config: nil)]
        )

        #expect(unconditional != conditional)
    }

    // With the synthesized (structural) implementations this would traverse
    // ~2^31 paths: enough to exceed the time limit, but small enough to still
    // terminate. The limit cannot interrupt synchronous work, so a much
    // deeper graph would hang CI instead of failing.
    @Test("Hashing modules of a deep diamond-shaped graph completes quickly", .timeLimit(.minutes(1)))
    func hashingDeepDiamondGraphCompletes() throws {
        let package = try ResolvedGraphFixtures.diamondChainPackage(depth: 30)

        var modules = Set<ResolvedModule>()
        for target in package.targets {
            modules.insert(target)
        }

        #expect(modules.count == package.targets.count)
    }
}
