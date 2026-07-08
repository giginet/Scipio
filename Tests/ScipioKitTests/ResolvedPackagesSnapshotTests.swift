import Foundation
import PackageManifestKit
import Testing
@testable import ScipioKit
@testable import ScipioKitCore

struct ResolvedPackagesSnapshotTests {
    private let jsonEncoder = ResolvedGraphFixtures.makeCanonicalJSONEncoder()
    private let jsonDecoder = JSONDecoder()

    // MARK: Round trip

    @Test("A resolved graph round-trips through encoding and restoring")
    func roundTripPreservesGraph() throws {
        let original = [try ResolvedGraphFixtures.diamondChainPackage(depth: 12)]

        let data = try jsonEncoder.encode(ResolvedPackagesSnapshot(resolvedPackages: original))
        let restored = try jsonDecoder.decode(ResolvedPackagesSnapshot.self, from: data).restoreResolvedPackages()

        // `==` compares modules and products by identity; the canonical-bytes
        // comparison and the value-level spot checks cover the deep structure.
        #expect(restored == original)
        #expect(try jsonEncoder.encode(ResolvedPackagesSnapshot(resolvedPackages: restored)) == data)

        let restoredPackage = try #require(restored.first)
        let originalPackage = try #require(original.first)
        #expect(restoredPackage.manifest == originalPackage.manifest)
        #expect(restoredPackage.pinState == originalPackage.pinState)

        let restoredRoot = try #require(restoredPackage.targets.last)
        let originalRoot = try #require(originalPackage.targets.last)
        #expect(restoredRoot.underlying == originalRoot.underlying)
        // Edge kinds, order, and conditions, compared by value.
        #expect(restoredRoot.dependencies == originalRoot.dependencies)
    }

    @Test("Restoring produces one value per identity")
    func restoreProducesOneValuePerIdentity() throws {
        let original = [try ResolvedGraphFixtures.diamondChainPackage(depth: 12)]
        let snapshot = ResolvedPackagesSnapshot(resolvedPackages: original)

        let restored = try snapshot.restoreResolvedPackages()

        // The same collection `PackageResolver.restoreCache` performs.
        let allModules = Set(
            try restored.flatMap(\.targets).flatMap { target in
                [target] + (try target.recursiveModuleDependencies())
            }
        )
        #expect(allModules.count == snapshot.modules.count)
    }

    // A regression to tree expansion would make the deep encoding ~2^10 times
    // larger instead of ~2 times.
    @Test("The encoded size grows linearly with the graph depth", .timeLimit(.minutes(1)))
    func encodedSizeGrowsLinearly() throws {
        let shallow = try encodedSize(depth: 10)
        let deep = try encodedSize(depth: 20)

        #expect(deep < shallow * 3)
        #expect(deep < 200_000)
    }

    // MARK: Validation of untrusted snapshots

    @Test("Restoring rejects an unsupported format version")
    func rejectsUnsupportedFormatVersion() throws {
        var snapshot = try makeSnapshot()
        snapshot.formatVersion = 99

        #expect(throws: ResolvedPackagesSnapshot.RestoreError.unsupportedFormatVersion(found: 99, supported: 1)) {
            try snapshot.restoreResolvedPackages()
        }
    }

    @Test("Restoring rejects dangling references")
    func rejectsDanglingReferences() throws {
        var tamperedEdge = try makeSnapshot()
        let index = try #require(tamperedEdge.modules.firstIndex { !$0.dependencies.isEmpty })
        tamperedEdge.modules[index].dependencies[0].index = 9_999
        #expect(throws: ResolvedPackagesSnapshot.RestoreError.invalidModuleReference(index: 9_999)) {
            try tamperedEdge.restoreResolvedPackages()
        }

        var tamperedPackage = try makeSnapshot()
        tamperedPackage.packages[0].productIndices = [9_999]
        #expect(throws: ResolvedPackagesSnapshot.RestoreError.invalidProductReference(index: 9_999)) {
            try tamperedPackage.restoreResolvedPackages()
        }
    }

    @Test("Restoring rejects duplicated identities instead of trapping")
    func rejectsDuplicatedIdentities() throws {
        var duplicatedModule = try makeSnapshot()
        duplicatedModule.modules.append(duplicatedModule.modules[0])
        #expect(throws: ResolvedPackagesSnapshot.RestoreError.duplicateModuleIdentity(duplicatedModule.modules[0].identity)) {
            try duplicatedModule.restoreResolvedPackages()
        }

        var duplicatedPackage = try makeSnapshot()
        duplicatedPackage.packages.append(duplicatedPackage.packages[0])
        let identity = duplicatedPackage.packages[0].packageIdentity
        #expect(throws: ResolvedPackagesSnapshot.RestoreError.duplicatePackageIdentity(identity)) {
            try duplicatedPackage.restoreResolvedPackages()
        }
    }

    @Test("Restoring rejects a dependency cycle instead of hanging")
    func rejectsDependencyCycle() throws {
        var snapshot = try makeSnapshot(depth: 2)
        // Close a cycle by making the leaf depend back on its dependent.
        let dependentIndex = try #require(snapshot.modules.firstIndex { !$0.dependencies.isEmpty })
        let leafIndex = try #require(snapshot.modules.firstIndex { $0.dependencies.isEmpty })
        snapshot.modules[leafIndex].dependencies = [
            .init(kind: .module, index: dependentIndex, conditions: []),
        ]

        #expect(throws: ResolvedPackagesSnapshot.RestoreError.dependencyCycleDetected) {
            try snapshot.restoreResolvedPackages()
        }
    }

    @Test("Dependency depth is capped at the supported maximum")
    func enforcesDependencyDepthLimit() throws {
        let maxDepth = ResolvedPackagesSnapshot.maxDependencyDepth

        // At the limit, restoring and re-flattening (the cross-storage sharing
        // path) must both stay iterative; recursion would overflow the stack.
        let restored = try makeChainSnapshot(depth: maxDepth).restoreResolvedPackages()
        #expect(restored.first?.targets.first?.underlying.name == "Module0")
        #expect(ResolvedPackagesSnapshot(resolvedPackages: restored).modules.count == maxDepth)

        #expect(throws: ResolvedPackagesSnapshot.RestoreError.dependencyChainTooDeep(depth: maxDepth + 1)) {
            try makeChainSnapshot(depth: maxDepth + 1).restoreResolvedPackages()
        }
    }

    // MARK: Helpers

    private func makeSnapshot(depth: Int = 4) throws -> ResolvedPackagesSnapshot {
        ResolvedPackagesSnapshot(resolvedPackages: [try ResolvedGraphFixtures.diamondChainPackage(depth: depth)])
    }

    private func encodedSize(depth: Int) throws -> Int {
        let packages = [try ResolvedGraphFixtures.diamondChainPackage(depth: depth)]
        return try jsonEncoder.encode(ResolvedPackagesSnapshot(resolvedPackages: packages)).count
    }

    /// A snapshot of one package whose first target heads a linear dependency
    /// chain, built from records directly so that arbitrary depths don't
    /// require building the equally deep value graph first.
    private func makeChainSnapshot(depth: Int) throws -> ResolvedPackagesSnapshot {
        let packageID = ResolvedGraphFixtures.packageID()

        var snapshot = ResolvedPackagesSnapshot(resolvedPackages: [])
        snapshot.modules = try (0..<depth).map { index in
            ResolvedPackagesSnapshot.ModuleRecord(
                underlying: try ResolvedGraphFixtures.target(name: "Module\(index)"),
                dependencies: index + 1 < depth ? [.init(kind: .module, index: index + 1, conditions: [])] : [],
                localPackageURL: URL(filePath: "/tmp/example-package"),
                packageID: packageID,
                resolvedModuleType: .swift
            )
        }
        snapshot.packages = [
            ResolvedPackagesSnapshot.PackageRecord(
                packageIdentity: packageID.packageIdentity,
                manifest: try ResolvedGraphFixtures.manifest(identity: packageID.packageIdentity),
                resolvedPackageKind: .remoteSourceControl(ResolvedGraphFixtures.packageURLString(packageID.packageIdentity)),
                path: "/tmp/example-package",
                pinState: nil,
                targetIndices: [0],
                productIndices: []
            ),
        ]
        return snapshot
    }
}
