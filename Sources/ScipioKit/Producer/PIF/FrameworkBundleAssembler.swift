import Foundation
import TSCBasic

/// FileLists to assemble a framework bundle
struct FrameworkComponents {
    var name: String
    var binaryPath: AbsolutePath
    var swiftModulePaths: Set<AbsolutePath>?
    var headerPaths: Set<AbsolutePath>
    var modulemapPath: AbsolutePath?
}

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
        let headers = frameworkComponents.headerPaths

        guard headers.isEmpty else {
            return
        }

        let headerDir = frameworkBundlePath.appending(component: "Headers")

        try fileSystem.createDirectory(headerDir)


        for header in frameworkComponents.headerPaths {
            try fileSystem.copy(
                from: header,
                to: headerDir.appending(component: header.basename)
            )
        }
    }

    private func relocateModules() throws {
        let needToCopy = [
            frameworkComponents.swiftModulePaths,
            frameworkComponents.modulemapPath.flatMap { [$0] },
        ]
            .compactMap { $0 }
            .flatMap { $0 }

        guard needToCopy.isEmpty else {
            return
        }

        let modulesDir = frameworkBundlePath.appending(component: "Modules")

        try fileSystem.createDirectory(modulesDir)

        for path in needToCopy {
            try fileSystem.copy(
                from: path,
                to: modulesDir
            )
        }
    }

    private func generateInfoPlist() throws {
        let infoPlistGenerator = InfoPlistGenerator(fileSystem: fileSystem)

        let infoPlistPath = frameworkBundlePath.appending(component: "Info.plist")

        try infoPlistGenerator.generate(for: .framework, at: infoPlistPath)
    }
}
