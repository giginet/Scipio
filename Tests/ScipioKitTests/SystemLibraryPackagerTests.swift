import Foundation
import Testing
@testable import ScipioKit

private let fixturePath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources")
    .appendingPathComponent("Fixtures")

struct SystemLibraryPackagerTests {
    private let fileManager: FileManager = .default

    /// Copies the fixture into a temporary directory: tests mutate the package
    /// contents and share nothing with the in-place fixture builds.
    private func makeTemporaryFixture(named name: String) throws -> URL {
        let destinationRoot = fileManager.temporaryDirectory
            .appendingPathComponent("SystemLibraryPackagerTests")
            .appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let destination = destinationRoot.appendingPathComponent(name)
        try fileManager.copyItem(at: fixturePath.appendingPathComponent(name), to: destination)
        try? fileManager.removeItem(at: destination.appendingPathComponent(".build"))
        return destination
    }

    private func makePackager(
        packageDirectory: URL,
        sdks: Set<SDK>
    ) async throws -> (packager: SystemLibraryPackager, buildProducts: [String: BuildProduct]) {
        let descriptionPackage = try await DescriptionPackage(
            packageDirectory: packageDirectory,
            mode: .createPackage,
            resolvedPackagesCachePolicies: [],
            onlyUseVersionsFromResolvedFile: false
        )
        let buildOptions = BuildOptions(
            buildConfiguration: .release,
            isDebugSymbolsEmbedded: false,
            frameworkType: .static,
            sdks: sdks,
            extraFlags: nil,
            extraBuildParameters: nil,
            enableLibraryEvolution: false,
            keepPublicHeadersStructure: false,
            customFrameworkModuleMapContents: nil,
            stripStaticDWARFSymbols: false
        )
        let packager = SystemLibraryPackager(
            descriptionPackage: descriptionPackage,
            buildOptions: buildOptions,
            keepPublicHeadersStructure: { _ in false }
        )
        let buildProducts = try descriptionPackage.resolveBuildProductDependencyGraph()
            .allNodes
            .reduce(into: [String: BuildProduct]()) { $0[$1.value.target.name] = $1.value }
        return (packager, buildProducts)
    }

    @Test
    func packagesMacCatalystSlice() async throws {
        let packageDirectory = try makeTemporaryFixture(named: "PackageWithSystemLibraryTarget")
        defer { try? fileManager.removeItem(at: packageDirectory.deletingLastPathComponent()) }
        let (packager, buildProducts) = try await makePackager(
            packageDirectory: packageDirectory,
            sdks: [.macCatalyst]
        )
        let sysShim = try #require(buildProducts["SysShim"])

        let outputDirectory = packageDirectory.appendingPathComponent("XCFrameworks")
        try await packager.createXCFramework(
            buildProduct: sysShim,
            outputDirectory: outputDirectory,
            overwrite: false
        )

        // The slice must be identified as Mac Catalyst, not macOS: the stub is
        // compiled against the macOS SDK but marked with the macabi target triple.
        let catalystFramework = outputDirectory.appendingPathComponent(
            "SysShim.xcframework/ios-arm64_x86_64-maccatalyst/SysShim.framework"
        )
        #expect(fileManager.fileExists(atPath: catalystFramework.appendingPathComponent("SysShim").path))
        #expect(fileManager.fileExists(atPath: catalystFramework.appendingPathComponent("Modules/module.modulemap").path))
    }

    @Test
    func throwsWhenModuleMapIsMissing() async throws {
        let packageDirectory = try makeTemporaryFixture(named: "PackageWithSystemLibraryTarget")
        defer { try? fileManager.removeItem(at: packageDirectory.deletingLastPathComponent()) }
        let (packager, buildProducts) = try await makePackager(
            packageDirectory: packageDirectory,
            sdks: [.iOS]
        )
        let sysShim = try #require(buildProducts["SysShim"])

        try fileManager.removeItem(
            at: packageDirectory.appendingPathComponent("Sources/SysShim/module.modulemap")
        )

        await #expect {
            try await packager.createXCFramework(
                buildProduct: sysShim,
                outputDirectory: packageDirectory.appendingPathComponent("XCFrameworks"),
                overwrite: false
            )
        } throws: { error in
            guard case SystemLibraryPackager.Error.moduleMapNotFound = error else { return false }
            return true
        }
    }

    @Test
    func throwsForNonSystemModuleType() async throws {
        let packageDirectory = try makeTemporaryFixture(named: "PackageWithSystemLibraryTarget")
        defer { try? fileManager.removeItem(at: packageDirectory.deletingLastPathComponent()) }
        let (packager, buildProducts) = try await makePackager(
            packageDirectory: packageDirectory,
            sdks: [.iOS]
        )
        let coreLib = try #require(buildProducts["CoreLib"])

        await #expect {
            try await packager.createXCFramework(
                buildProduct: coreLib,
                outputDirectory: packageDirectory.appendingPathComponent("XCFrameworks"),
                overwrite: false
            )
        } throws: { error in
            guard case SystemLibraryPackager.Error.unexpectedModuleType = error else { return false }
            return true
        }
    }
}
