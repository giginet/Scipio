import Foundation
import TSCBasic

/// A assembler to generate framework bundle
/// This assembler just relocates framework components into the framework structure
struct FrameworkBundleAssembler {
    private let frameworkComponents: FrameworkComponents
    private let outputDirectory: AbsolutePath
    private let fileSystem: any FileSystem

    private var frameworkBundlePath: AbsolutePath {
        outputDirectory.appending(component: "\(frameworkComponents.name).framework")
    }

    init(frameworkComponents: FrameworkComponents, outputDirectory: AbsolutePath, fileSystem: some FileSystem) {
        self.frameworkComponents = frameworkComponents
        self.outputDirectory = outputDirectory
        self.fileSystem = fileSystem
    }

    @discardableResult
    func assemble() throws -> AbsolutePath {
        try fileSystem.createDirectory(frameworkBundlePath, recursive: true)

        // Copy binary
        let binaryPath = frameworkBundlePath.appending(component: frameworkComponents.name)
        try fileSystem.copy(from: frameworkComponents.binaryPath, to: binaryPath)

        try relocateHeaders()

        try relocateModules()

        try generateInfoPlist()

        return frameworkBundlePath
    }

    private func relocateHeaders() throws {
        let headers = (frameworkComponents.publicHeaderPaths ?? [])
        + (frameworkComponents.bridgingHeaderPath.flatMap { [$0] } ?? [])

        guard !headers.isEmpty else {
            return
        }

        let headerDir = frameworkBundlePath.appending(component: "Headers")

        try fileSystem.createDirectory(headerDir)

        for header in headers {
            try fileSystem.copy(
                from: header,
                to: headerDir.appending(component: header.basename)
            )
        }
    }

    private func relocateModules() throws {
        let modules = [
            frameworkComponents.swiftModulesPath,
            frameworkComponents.modulemapPath,
        ]
            .compactMap { $0 }

        let needToGenerateModules = !modules.isEmpty

        guard needToGenerateModules else {
            return
        }

        let modulesDir = frameworkBundlePath.appending(component: "Modules")

        try fileSystem.createDirectory(modulesDir)

        if let swiftModulesPath = frameworkComponents.swiftModulesPath {
            try fileSystem.copy(
                from: swiftModulesPath,
                to: modulesDir.appending(component: swiftModulesPath.basename)
            )
        }

        if let moduleMapPath = frameworkComponents.modulemapPath {
            try fileSystem.copy(
                from: moduleMapPath,
                to: modulesDir.appending(component: "module.modulemap")
            )
        }
    }

    private func generateInfoPlist() throws {
        let infoPlistGenerator = InfoPlistGenerator(fileSystem: fileSystem)

        let infoPlistPath = frameworkBundlePath.appending(component: "Info.plist")

        try infoPlistGenerator.generate(for: .framework, at: infoPlistPath)
    }
}
