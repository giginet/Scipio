import Foundation
import Basics

/// A assembler to generate framework bundle
/// This assembler just relocates framework components into the framework structure
struct FrameworkBundleAssembler {
    private let frameworkComponents: FrameworkComponents
    private let keepPublicHeadersStructure: Bool
    private let outputDirectory: TSCAbsolutePath
    private let fileSystem: any FileSystem

    private var frameworkBundlePath: TSCAbsolutePath {
        outputDirectory.appending(component: "\(frameworkComponents.frameworkName).framework")
    }

    init(
        frameworkComponents: FrameworkComponents,
        keepPublicHeadersStructure: Bool,
        outputDirectory: TSCAbsolutePath,
        fileSystem: some FileSystem
    ) {
        self.frameworkComponents = frameworkComponents
        self.keepPublicHeadersStructure = keepPublicHeadersStructure
        self.outputDirectory = outputDirectory
        self.fileSystem = fileSystem
    }

    @discardableResult
    func assemble() throws -> URL {
        try fileSystem.createDirectory(frameworkBundlePath, recursive: true)

        try copyBinary()

        try copyHeaders()

        try copyModules()

        let resourcesProcessor = ResourcesProcessor(fileSystem: fileSystem)
        try resourcesProcessor.copyResources(
            sourceContext: .init(
                isFrameworkVersionedBundle: frameworkComponents.isVersionedBundle,
                frameworkBundlePath: frameworkComponents.frameworkPath,
                frameworkInfoPlistPath: frameworkComponents.infoPlistPath,
                resourceBundlePath: frameworkComponents.resourceBundlePath
            ),
            destinationFrameworkBundlePath: frameworkBundlePath
        )

        return frameworkBundlePath.asURL
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
        header: TSCAbsolutePath,
        includeDir: TSCAbsolutePath,
        into headerDir: TSCAbsolutePath
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
}

extension FrameworkBundleAssembler {
    struct ResourcesProcessor {
        struct SourceContext {
            let isFrameworkVersionedBundle: Bool
            let frameworkBundlePath: TSCAbsolutePath
            let frameworkInfoPlistPath: TSCAbsolutePath
            let resourceBundlePath: TSCAbsolutePath?
        }

        private let fileSystem: any FileSystem

        init(fileSystem: some FileSystem) {
            self.fileSystem = fileSystem
        }

        func copyResources(
            sourceContext: SourceContext,
            destinationFrameworkBundlePath: TSCAbsolutePath
        ) throws {
            if sourceContext.isFrameworkVersionedBundle {
                // The framework is a versioned bundle, so copy entire Resources directory
                // instead of copying its Info.plist and resource bundle separately.
                let sourceResourcesPath = sourceContext.frameworkBundlePath.appending(component: "Resources")
                let destinationResourcesPath = destinationFrameworkBundlePath.appending(component: "Resources")
                try fileSystem.copy(
                    from: sourceResourcesPath.asURL.resolvingSymlinksInPath().absolutePath,
                    to: destinationResourcesPath
                )

                if let resourceBundleName = sourceContext.resourceBundlePath?.basename {
                    let resourceBundlePath = destinationResourcesPath.appending(component: resourceBundleName)
                    // A resource bundle of versioned bundle framework has "Contents/Resources" directory.
                    try extractPrivacyInfoIfExists(
                        from: TSCRelativePath(validating: "Contents/Resources/PrivacyInfo.xcprivacy"),
                        in: resourceBundlePath
                    )
                }
            } else {
                try copyInfoPlist(
                    sourceContext: sourceContext,
                    destinationFrameworkBundlePath: destinationFrameworkBundlePath
                )
                let copiedResourceBundlePath = try copyResourceBundle(
                    sourceContext: sourceContext,
                    destinationFrameworkBundlePath: destinationFrameworkBundlePath
                )

                if let copiedResourceBundlePath {
                    try extractPrivacyInfoIfExists(
                        from: TSCRelativePath(validating: "PrivacyInfo.xcprivacy"),
                        in: copiedResourceBundlePath
                    )
                }
            }
        }

        private func copyInfoPlist(
            sourceContext: SourceContext,
            destinationFrameworkBundlePath: TSCAbsolutePath
        ) throws {
            let sourcePath = sourceContext.frameworkInfoPlistPath
            let destinationPath = destinationFrameworkBundlePath.appending(component: "Info.plist")
            try fileSystem.copy(from: sourcePath, to: destinationPath)
        }

        /// Returns the resulting, copied resource bundle path.
        private func copyResourceBundle(
            sourceContext: SourceContext,
            destinationFrameworkBundlePath: TSCAbsolutePath
        ) throws -> TSCAbsolutePath? {
            if let sourcePath = sourceContext.resourceBundlePath {
                let destinationPath = destinationFrameworkBundlePath.appending(component: sourcePath.basename)
                try fileSystem.copy(from: sourcePath, to: destinationPath)
                return destinationPath
            } else {
                return nil
            }
        }

        /// Extracts PrivacyInfo.xcprivacy to expected location (if exists in the resource bundle).
        ///
        /// - seealso: https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk#Add-a-privacy-manifest-to-your-framework
        private func extractPrivacyInfoIfExists(
            from relativePrivacyInfoPath: TSCRelativePath,
            in resourceBundlePath: TSCAbsolutePath
        ) throws {
            let privacyInfoPath = resourceBundlePath.appending(relativePrivacyInfoPath)
            if fileSystem.exists(privacyInfoPath) {
                try fileSystem.move(
                    from: privacyInfoPath,
                    to: resourceBundlePath.parentDirectory.appending(component: relativePrivacyInfoPath.basename)
                )
            }
        }
    }
}
