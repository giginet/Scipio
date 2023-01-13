import Foundation
import XCTest
import XcodeProj
@testable import ScipioKit

private let fixturePath = URL(fileURLWithPath: #file)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources")
    .appendingPathComponent("Fixtures")
private let testPackagePath = fixturePath.appendingPathComponent("E2ETestPackage")
private let clangPackagePath = fixturePath.appendingPathComponent("ClangPackage")
private let resourcePackagePath = fixturePath.appendingPathComponent("ResourcePackage")
private let settingsPackagePath = fixturePath.appendingPathComponent("SettingsPackage")

final class ProjectGeneratorTests: XCTestCase {
    private let fileSystem: some FileSystem = localFileSystem

    private func makeGenerator(for package: Package) throws -> ProjectGenerator {
        ProjectGenerator(package: package,
                         buildOptions: .init(buildConfiguration: .debug,
                                             isSimulatorSupported: true,
                                             isDebugSymbolsEmbedded: false,
                                             frameworkType: .static,
                                             sdks: [.iOS]),
                         fileSystem: localFileSystem)
    }

    func testGeneratedProject() throws {
        let package = try Package(packageDirectory: testPackagePath)
        let projectGenerator = try makeGenerator(for: package)
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

        // Check platform settings
        for configuration in testingPackageTarget.buildConfigurationList!.buildConfigurations {
            XCTAssertEqual(
                configuration.buildSettings["TARGETED_DEVICE_FAMILY"] as? String,
                "1,2" // iPhone & iPad
            )
            XCTAssertEqual(
                configuration.buildSettings["SUPPORTED_PLATFORMS"] as? String,
                "iphoneos iphonesimulator"
            )
            XCTAssertEqual(
                configuration.buildSettings["SUPPORTS_MACCATALYST"] as? String,
                "NO"
            )
        }
    }

    func testGeneratedClangTarget() throws {
        let package = try Package(packageDirectory: clangPackagePath)
        let projectGenerator = try makeGenerator(for: package)
        let projectPath = package.projectPath
        try projectGenerator.generate()
        XCTAssertTrue(fileSystem.exists(projectPath))

        let project = try XcodeProj(pathString: projectPath.path)

        // Check targets
        let targets = project.pbxproj.nativeTargets
        XCTAssertEqual(Set(targets.map(\.name)), ["some_lib"])

        let target = try XCTUnwrap(project.pbxproj.targets(named: "some_lib").first)

        // Check file tree
        XCTAssertEqual(Set(project.pbxproj.groups.compactMap(\.name)), ["some_lib", "include", "Products"])
        let rootGroup = try XCTUnwrap(project.pbxproj.rootGroup())
        let libraryGroup = try XCTUnwrap(rootGroup.group(named: "some_lib"))
        XCTAssertNotNil(libraryGroup.file(named: "some_lib.c"))

        let includeGroup = try XCTUnwrap(libraryGroup.group(named: "include"))
        XCTAssertNotNil(includeGroup.file(named: "some_lib.h"))

        // Check build phase
        let buildPhase = try XCTUnwrap(try target.sourcesBuildPhase())
        XCTAssertEqual(buildPhase.files?.count, 1)

        // Check header
        let headerBuildPhase = try XCTUnwrap(target.buildPhases.first(where: { $0 is PBXHeadersBuildPhase }) as? PBXHeadersBuildPhase)
        let publicHeader = try XCTUnwrap(headerBuildPhase.files?.first)
        XCTAssertEqual(publicHeader.file?.path, "some_lib.h")
        XCTAssertEqual(publicHeader.settings?["ATTRIBUTES"] as! [String], ["Public"])

        // Check build settings
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
            XCTAssertEqual(
                configuration.buildSettings["CLANG_ENABLE_MODULES"] as? String,
                "YES"
            )
            XCTAssertEqual(
                configuration.buildSettings["DEFINES_MODULE"] as? String,
                "YES"
            )
        }
    }

    func testGeneratedResourcePackageProject() async throws {
        let package = try Package(packageDirectory: resourcePackagePath)
        let projectGenerator = try makeGenerator(for: package)
        let projectPath = package.projectPath
        try projectGenerator.generate()
        XCTAssertTrue(fileSystem.exists(projectPath))

        let project = try XcodeProj(pathString: projectPath.path)

        // Check targets
        let targets = project.pbxproj.nativeTargets
        XCTAssertEqual(Set(targets.map(\.name)), ["ResourcePackage", "ResourcePackage-Resources"])

        let frameworkTarget = try XCTUnwrap(project.pbxproj.targets(named: "ResourcePackage").first)
        let resourceTarget = try XCTUnwrap(project.pbxproj.targets(named: "ResourcePackage-Resources").first)

        XCTAssertEqual(resourceTarget.productType, .bundle)

        // Check file tree
        XCTAssertEqual(Set(project.pbxproj.groups.compactMap(\.name)), ["ResourcePackage", "ResourcePackage-Resources", "Products"])
        let rootGroup = try XCTUnwrap(project.pbxproj.rootGroup())
        let bundleGroup = try XCTUnwrap(rootGroup.group(named: "ResourcePackage-Resources"))
        XCTAssertEqual(Set(bundleGroup.children.map(\.name)), ["giginet.png", "AvatarView.xib"])

        // Check build phase
        let resourcePhaseFiles = try XCTUnwrap(try resourceTarget.resourcesBuildPhase()?.files)
        XCTAssertEqual(
            Set(resourcePhaseFiles.map(\.file?.name)),
            ["giginet.png", "AvatarView.xib"]
        )

        XCTAssertEqual(
            frameworkTarget.dependencies.map(\.target?.name), ["ResourcePackage-Resources"],
            "The resource bundle target must be dependency"
        )

        // Check build settings
        XCTAssertEqual(resourceTarget.buildConfigurationList?.buildConfigurations.map(\.name), ["Debug", "Release"])
        for configuration in resourceTarget.buildConfigurationList!.buildConfigurations {
            XCTAssertEqual(
                configuration.buildSettings["INFOPLIST_FILE"] as? String,
                resourcePackagePath
                    .appendingPathComponent(".build")
                    .appendingPathComponent("ResourcePackage-Resources_Info.plist")
                    .path
            )
            XCTAssertEqual(
                configuration.buildSettings["CODE_SIGNING_ALLOWED"] as? String,
                "NO"
            )
            XCTAssertEqual(
                configuration.buildSettings["SUPPORTED_PLATFORMS"] as? String,
                "iphoneos iphonesimulator"
            )
        }
    }

    func testSettingsPackageProject() async throws {
        let package = try Package(packageDirectory: settingsPackagePath)
        let projectGenerator = try makeGenerator(for: package)
        let projectPath = package.projectPath
        try projectGenerator.generate()
        XCTAssertTrue(fileSystem.exists(projectPath))

        let project = try XcodeProj(pathString: projectPath.path)
        let target = try XCTUnwrap(project.pbxproj.nativeTargets.first)

        let configuration = try XCTUnwrap(target.buildConfigurationList?.buildConfigurations.first)
        print(configuration.buildSettings)
        XCTAssertEqual(
            configuration.buildSettings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] as! [String],
            ["$(inherited)", "MY_FLAG", "ANOTHER_FLAG"]
        )
    }
}
