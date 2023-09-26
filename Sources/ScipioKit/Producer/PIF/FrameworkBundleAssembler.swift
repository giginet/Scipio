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
        let sourcePath = frameworkComponents.binaryPath
        let destinationPath = frameworkBundlePath.appending(component: frameworkComponents.name)
        if fileSystem.isSymlink(sourcePath) {
            // Frameworks for macOS have Versions. So their binaries are symlinks
            // Follow symlink to copy a original binary
            let sourceURL = sourcePath.asURL
            try fileSystem.copy(
                from: sourceURL.resolvingSymlinksInPath().absolutePath,
                to: destinationPath
            )
        } else {
            try fileSystem.copy(
                from: frameworkComponents.binaryPath,
                to: destinationPath
            )
        }

        try relocateHeaders()

        try relocateModules()

        if let resourceBundlePath = frameworkComponents.resourceBundlePath {
            let destinationPath = frameworkBundlePath.appending(component: resourceBundlePath.basename)
            try fileSystem.copy(from: resourceBundlePath, to: destinationPath)
        }

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
