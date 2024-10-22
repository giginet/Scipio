import Foundation
import TSCBasic

/// A assembler to generate framework bundle
/// This assembler just relocates framework components into the framework structure
struct FrameworkBundleAssembler {
    private let frameworkComponents: FrameworkComponents
    private let keepPublicHeadersStructure: Bool
    private let outputDirectory: AbsolutePath
    private let fileSystem: any FileSystem

    private var frameworkBundlePath: AbsolutePath {
        outputDirectory.appending(component: "\(frameworkComponents.frameworkName).framework")
    }

    init(
        frameworkComponents: FrameworkComponents,
        keepPublicHeadersStructure: Bool,
        outputDirectory: AbsolutePath,
        fileSystem: some FileSystem
    ) {
        self.frameworkComponents = frameworkComponents
        self.keepPublicHeadersStructure = keepPublicHeadersStructure
        self.outputDirectory = outputDirectory
        self.fileSystem = fileSystem
    }

    @discardableResult
    func assemble() throws -> AbsolutePath {
        try fileSystem.createDirectory(frameworkBundlePath, recursive: true)

        try copyInfoPlist()

        try copyBinary()

        try copyHeaders()

        try copyModules()

        try copyResources()

        return frameworkBundlePath
    }

    private func copyInfoPlist() throws {
        let sourcePath = frameworkComponents.infoPlistPath
        let destinationPath = frameworkBundlePath.appending(component: "Info.plist")
        try fileSystem.copy(from: sourcePath, to: destinationPath)
    }

    private func copyBinary() throws {
        let sourcePath = frameworkComponents.binaryPath
        let destinationPath = frameworkBundlePath.appending(component: frameworkComponents.frameworkName)
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
    }

    private func copyHeaders() throws {
        let headers = (frameworkComponents.publicHeaderPaths ?? [])
        + (frameworkComponents.bridgingHeaderPath.flatMap { [$0] } ?? [])

        guard !headers.isEmpty else {
            return
        }

        let headerDir = frameworkBundlePath.appending(component: "Headers")

        try fileSystem.createDirectory(headerDir)

        for header in headers {
            if keepPublicHeadersStructure, let includeDir = frameworkComponents.includeDir {
                try copyHeaderKeepingStructure(
                    header: header,
                    includeDir: includeDir,
                    into: headerDir
                )
            } else {
                try fileSystem.copy(
                    from: header,
                    to: headerDir.appending(component: header.basename)
                )
            }
        }
    }

    private func copyHeaderKeepingStructure(
        header: AbsolutePath,
        includeDir: AbsolutePath,
        into headerDir: AbsolutePath
    ) throws {
        let subdirectoryComponents: [String] = if header.dirname.hasPrefix(includeDir.pathString) {
            header.dirname.dropFirst(includeDir.pathString.count)
                .split(separator: "/")
                .map(String.init)
        } else {
            []
        }

        if !subdirectoryComponents.isEmpty {
            try fileSystem.createDirectory(
                headerDir.appending(components: subdirectoryComponents),
                recursive: true
            )
        }
        try fileSystem.copy(
            from: header,
            to: headerDir
                .appending(components: subdirectoryComponents)
                .appending(component: header.basename)
        )
    }

    private func copyModules() throws {
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

    private func copyResources() throws {
        if let resourceBundlePath = frameworkComponents.resourceBundlePath {
            let destinationPath = frameworkBundlePath.appending(component: resourceBundlePath.basename)
            try fileSystem.copy(from: resourceBundlePath, to: destinationPath)
        }
    }
}
