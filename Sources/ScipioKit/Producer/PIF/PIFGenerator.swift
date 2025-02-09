import Foundation
import Basics
import PIFKit
import SPMBuildCore
import PackageModel
import PackageGraph
import XCBuildSupport

struct PIFGenerator {
    private let packageName: String
    private let packageLocator: any PackageLocator
    private let buildParameters: BuildParameters
    private let buildOptions: BuildOptions
    private let buildOptionsMatrix: [String: BuildOptions]
    private let executor: any Executor
    private let fileSystem: any FileSystem

    init(
        packageName: String,
        packageLocator: some PackageLocator,
        buildParameters: BuildParameters,
        buildOptions: BuildOptions,
        buildOptionsMatrix: [String: BuildOptions],
        executor: some Executor = ProcessExecutor(),
        fileSystem: any FileSystem = localFileSystem
    ) throws {
        self.packageName = packageName
        self.packageLocator = packageLocator
        self.buildParameters = buildParameters
        self.buildOptions = buildOptions
        self.buildOptionsMatrix = buildOptionsMatrix
        self.executor = executor
        self.fileSystem = fileSystem
    }

    private func buildPIFManipulator() async throws -> PIFManipulator {
        let commands = [
            "/usr/bin/xcrun",
            "swift",
            "package",
            "dump-pif",
            "--package-path",
            packageLocator.packageDirectory.pathString,
        ]
        let jsonString = try await executor.execute(commands).unwrapOutput()
        let data = jsonString.data(using: .utf8)!
        return try PIFManipulator(jsonData: data)
    }

    func generateJSON(for sdk: SDK) async throws -> TSCAbsolutePath {
        let manipulator = try await buildPIFManipulator()

        manipulator.updateTargets { target in
            updateTarget(&target, sdk: sdk)
        }

        let newJSONData = try manipulator.dump()

        let path = packageLocator.workspaceDirectory
            .appending(component: "manifest-\(packageName)-\(sdk.settingValue).pif")
        try fileSystem.writeFileContents(path.spmAbsolutePath, data: newJSONData)
        return path
    }

    private func updateTarget(_ target: inout PIFKit.Target, sdk: SDK) {
        switch target.productType {
        case .objectFile:
            updateObjectFileTarget(&target, sdk: sdk)
        case .bundle:
            generateInfoPlistForResource(for: &target)
        default:
            break
        }
    }

    private func updateObjectFileTarget(_ target: inout PIFKit.Target, sdk: SDK) {
        target.productType = .framework

        for index in 0..<target.buildConfigurations.count {
            updateBuildConfiguration(&target.buildConfigurations[index], target: target, sdk: sdk)
        }
    }

    private func updateBuildConfiguration(_ configuration: inout PIFKit.BuildConfiguration, target: PIFKit.Target, sdk: SDK) {
        let name = target.name
        let c99Name = name.spm_mangledToC99ExtendedIdentifier()
        let toolchainLibDir = (try? buildParameters.toolchain.toolchainLibDir) ?? .root

        configuration.buildSettings["PRODUCT_NAME"] = "$(EXECUTABLE_NAME:c99extidentifier)"
        configuration.buildSettings["PRODUCT_MODULE_NAME"] = "$(EXECUTABLE_NAME:c99extidentifier)"
        configuration.buildSettings["EXECUTABLE_NAME"] = .string(c99Name)
        configuration.buildSettings["TARGET_NAME"] = .string(name)
        configuration.buildSettings["PRODUCT_BUNDLE_IDENTIFIER"] = .string(name.spm_mangledToBundleIdentifier())
        configuration.buildSettings["CLANG_ENABLE_MODULES"] = true
        configuration.buildSettings["DEFINES_MODULE"] = true
        configuration.buildSettings["SKIP_INSTALL"] = false
        configuration.buildSettings["INSTALL_PATH"] = "/usr/local/lib"
        configuration.buildSettings["ONLY_ACTIVE_ARCH"] = false
        configuration.buildSettings["SDKROOT"] = .string(sdk.settingValue)

        configuration.buildSettings["GENERATE_INFOPLIST_FILE"] = true
        // These values are required to ship built frameworks to AppStore as embedded frameworks
        configuration.buildSettings["MARKETING_VERSION"] = "1.0"
        configuration.buildSettings["CURRENT_PROJECT_VERSION"] = "1"

        let frameworkType = buildOptionsMatrix[name]?.frameworkType ?? buildOptions.frameworkType

        // Set framework type
        switch frameworkType {
        case .dynamic, .mergeable:
            configuration.buildSettings["MACH_O_TYPE"] = "mh_dylib"
        case .static:
            configuration.buildSettings["MACH_O_TYPE"] = "staticlib"
        }

        configuration.buildSettings["LIBRARY_SEARCH_PATHS"]
            .append("\(toolchainLibDir.pathString)/swift/\(sdk.settingValue)")

        // Enable to emit swiftinterface
        if buildOptions.enableLibraryEvolution {
            configuration.buildSettings["OTHER_SWIFT_FLAGS"]
                .append("-enable-library-evolution")
            configuration.buildSettings["SWIFT_EMIT_MODULE_INTERFACE"] = "YES"
        }
        configuration.buildSettings["SWIFT_INSTALL_OBJC_HEADER"] = "YES"

        if frameworkType == .mergeable {
            configuration.buildSettings["OTHER_LDFLAGS"]
                .append("-Wl,-make_mergeable")
        }

        appendExtraFlagsByBuildOptionsMatrix(to: &configuration, target: target)

        // Original PIFBuilder implementation of SwiftPM generates modulemap for Swift target
        // That modulemap refer a bridging header by a relative path
        // However, this PIFGenerator modified productType to framework.
        // So a bridging header will be generated in frameworks bundle even if `SWIFT_OBJC_INTERFACE_HEADER_DIR` was specified.
        // So it's need to replace `MODULEMAP_FILE_CONTENTS` to an absolute path.
        // Bridging Headers will be generated inside generated frameworks
        let productsDirectory = packageLocator.productsDirectory(
            buildConfiguration: buildOptions.buildConfiguration,
            sdk: sdk
        )
        let bridgingHeaderFullPath = productsDirectory.appending(
            components: ["\(c99Name).framework", "Headers", "\(name)-Swift.h"]
        )

        configuration.buildSettings["MODULEMAP_FILE_CONTENTS"] = .string("""
            module \(c99Name) {
                header "\(bridgingHeaderFullPath.pathString)"
                export *
            }
            """)
    }

    // Append extraFlags from BuildOptionsMatrix to each target settings
    private func appendExtraFlagsByBuildOptionsMatrix(to configuration: inout PIFKit.BuildConfiguration, target: PIFKit.Target) {
        func createOrUpdateFlags(for key: String, to keyPath: KeyPath<ExtraFlags, [String]?>) {
            if let extraFlags = self.buildOptionsMatrix[target.name]?.extraFlags?[keyPath: keyPath] {
                configuration.buildSettings[key].append(extraFlags)
            }
        }

        createOrUpdateFlags(for: "OTHER_CFLAGS", to: \.cFlags)
        createOrUpdateFlags(for: "OTHER_CPLUSPLUSFLAGS", to: \.cxxFlags)
        createOrUpdateFlags(for: "OTHER_SWIFT_FLAGS", to: \.swiftFlags)
        createOrUpdateFlags(for: "OTHER_LDFLAGS", to: \.linkerFlags)
    }

    private func generateInfoPlistForResource(for target: inout PIFKit.Target) {
        assert(target.productType == .bundle, "This method must be called for Resource bundles")

        let infoPlistGenerator = InfoPlistGenerator(fileSystem: fileSystem)
        let infoPlistPath = packageLocator.workspaceDirectory.appending(component: "Info-\(target.name).plist")
        do {
            try infoPlistGenerator.generateForResourceBundle(at: infoPlistPath)
        } catch {
            fatalError("Could not generate Info.plist file")
        }

        target.buildConfigurations = target.buildConfigurations.map { buildConfiguration in
            var mutableConfiguration = buildConfiguration
            // For resource bundle targets, generating Info.plist automatically in default.
            // However, generated Info.plist causes code signing issue when submitting to AppStore.
            // `CFBundleExecutable` is not allowed for Info.plist contains in resource bundles.
            // So generating a Info.plist and set this
            mutableConfiguration.buildSettings["GENERATE_INFOPLIST_FILE"] = false
            mutableConfiguration.buildSettings["INFOPLIST_FILE"] = .string(infoPlistPath.pathString)
            return mutableConfiguration
        }
    }
}
