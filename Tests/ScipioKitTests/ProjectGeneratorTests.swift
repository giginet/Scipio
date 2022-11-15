import Foundation
import XCTest
import XcodeProj
@testable import ScipioKit

private let fixturePath = URL(fileURLWithPath: #file)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources")
    .appendingPathComponent("Fixtures")
private let testPackagePath = fixturePath.appendingPathComponent("E2ETestPackage")

final class ProjectGeneratorTests: XCTestCase {
    private var projectGenerator: ProjectGenerator!
    private var package: Package!
    private let fileSystem: some FileSystem = localFileSystem

    override func setUpWithError() throws {
        package = try Package(packageDirectory: testPackagePath)
        projectGenerator = ProjectGenerator(package: package,
                                            buildOptions: .init(buildConfiguration: .debug,
                                                                isSimulatorSupported: false,
                                                                isDebugSymbolsEmbedded: false,
                                                                frameworkType: .static,
                                                                sdks: [.iOS]),
                                            fileSystem: localFileSystem)

        try super.setUpWithError()
    }

    func testGeneratedProject() throws {
        let projectPath = package.projectPath
        try projectGenerator.generate()
        XCTAssertTrue(fileSystem.exists(projectPath))

        let project = try XcodeProj(pathString: projectPath.path)

        // Check targets
        let targets = project.pbxproj.nativeTargets
        XCTAssertEqual(Set(targets.map(\.name)), ["TestingPackage", "ScipioTesting"])

        // Check file tree
        XCTAssertEqual(Set(project.pbxproj.groups.compactMap(\.name)), ["ScipioTesting", "TestingPackage", "Products"])
        let rootGroup = try XCTUnwrap(project.pbxproj.rootGroup())
        let scipioTestingGroup = try XCTUnwrap(rootGroup.group(named: "ScipioTesting"))
        XCTAssertEqual(scipioTestingGroup.children.map(\.name), ["dummy.swift"])

        // Check dependencies
        let testingPackageTarget = try XCTUnwrap(project.pbxproj.targets(named: "TestingPackage").first)
        let linkPhase = try XCTUnwrap(try testingPackageTarget.frameworksBuildPhase())
        XCTAssertEqual(linkPhase.files?.compactMap(\.file?.name), ["ScipioTesting.framework"])

        // Check build phase
        let buildPhase = try XCTUnwrap(try testingPackageTarget.sourcesBuildPhase())
        XCTAssertEqual(buildPhase.files?.count, 1)

        // Check build settings
        for target in targets {
            XCTAssertEqual(target.buildConfigurationList?.buildConfigurations.map(\.name), ["Debug", "Release"])
            for configuration in target.buildConfigurationList!.buildConfigurations {
                XCTAssertEqual(
                    configuration.buildSettings["MACH_O_TYPE"] as? String,
                    "staticlib", "If frameworkType is static, MACH_O_TYPE should be set"
                )
                XCTAssertEqual(
                    configuration.buildSettings["BUILD_LIBRARY_FOR_DISTRIBUTION"] as? String,
                    "YES"
                )
                XCTAssertEqual(
                    configuration.buildSettings["FRAMEWORK_SEARCH_PATHS"] as? [String],
                    ["$(inherited)", "$(PLATFORM_DIR)/Developer/Library/Frameworks"]
                )
            }
        }
    }
}
