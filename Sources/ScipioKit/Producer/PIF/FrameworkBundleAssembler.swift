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
    func assemble() async throws -> URL {
        try await fileSystem.createDirectory(frameworkBundlePath.asURL, recursive: true)

        try await copyBinary()

        try await copyHeaders()

        try await copyModules()

        let resourcesProcessor = ResourcesProcessor(fileSystem: fileSystem)
        try await resourcesProcessor.copyResources(
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

    private func copyBinary() async throws {
        let sourcePath = frameworkComponents.binaryPath
        let destinationPath = frameworkBundlePath.appending(component: frameworkComponents.frameworkName)
        if fileSystem.isSymlink(sourcePath.asURL) {
            // Frameworks for macOS have Versions. So their binaries are symlinks
            // Follow symlink to copy a original binary
            let sourceURL = sourcePath.asURL
            try await fileSystem.copy(
                from: sourceURL.resolvingSymlinksInPath(),
                to: destinationPath.asURL
            )
        } else {
            try await fileSystem.copy(
                from: frameworkComponents.binaryPath.asURL,
                to: destinationPath.asURL
            )
        }
    }

    private func copyHeaders() async throws {
        let headers = (frameworkComponents.publicHeaderPaths ?? [])
        + (frameworkComponents.bridgingHeaderPath.flatMap { [$0] } ?? [])

        guard !headers.isEmpty else {
            return
        }

        let headerDir = frameworkBundlePath.appending(component: "Headers")

        try await fileSystem.createDirectory(headerDir.asURL)

        for header in headers {
            if keepPublicHeadersStructure, let includeDir = frameworkComponents.includeDir {
                try await copyHeaderKeepingStructure(
                    header: header,
                    includeDir: includeDir,
                    into: headerDir
                )
            } else {
                try await fileSystem.copy(
                    from: header.asURL,
                    to: headerDir.appending(component: header.basename).asURL
                )
            }
        }
    }

    private func copyHeaderKeepingStructure(
        header: AbsolutePath,
        includeDir: AbsolutePath,
        into headerDir: AbsolutePath
    ) async throws {
        let subdirectoryComponents: [String] = if header.dirname.hasPrefix(includeDir.pathString) {
            header.dirname.dropFirst(includeDir.pathString.count)
                .split(separator: "/")
                .map(String.init)
        } else {
            []
        }

        if !subdirectoryComponents.isEmpty {
            try await fileSystem.createDirectory(
                headerDir.appending(components: subdirectoryComponents).asURL,
                recursive: true
            )
        }
        try await fileSystem.copy(
            from: header.asURL,
            to: headerDir
                .appending(components: subdirectoryComponents)
                .appending(component: header.basename)
                .asURL
        )
    }

    private func copyModules() async throws {
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

        try await fileSystem.createDirectory(modulesDir.asURL)

        if let swiftModulesPath = frameworkComponents.swiftModulesPath {
            try await fileSystem.copy(
                from: swiftModulesPath.asURL,
                to: modulesDir.appending(component: swiftModulesPath.basename).asURL
            )
        }

        if let moduleMapPath = frameworkComponents.modulemapPath {
            try await fileSystem.copy(
                from: moduleMapPath.asURL,
                to: modulesDir.appending(component: "module.modulemap").asURL
            )
        }
    }
}

extension FrameworkBundleAssembler {
    struct ResourcesProcessor {
        struct SourceContext {
            let isFrameworkVersionedBundle: Bool
            let frameworkBundlePath: AbsolutePath
            let frameworkInfoPlistPath: AbsolutePath
            let resourceBundlePath: AbsolutePath?
        }

        private let fileSystem: any FileSystem

        init(fileSystem: some FileSystem) {
            self.fileSystem = fileSystem
        }

        func copyResources(
            sourceContext: SourceContext,
            destinationFrameworkBundlePath: AbsolutePath
        ) async throws {
            if sourceContext.isFrameworkVersionedBundle {
                // The framework is a versioned bundle, so copy entire Resources directory
                // instead of copying its Info.plist and resource bundle separately.
                let sourceResourcesPath = sourceContext.frameworkBundlePath.appending(component: "Resources")
                let destinationResourcesPath = destinationFrameworkBundlePath.appending(component: "Resources")
                try await fileSystem.copy(
                    from: sourceResourcesPath.asURL.resolvingSymlinksInPath(),
                    to: destinationResourcesPath.asURL
                )

                if let resourceBundleName = sourceContext.resourceBundlePath?.basename {
                    let resourceBundlePath = destinationResourcesPath.appending(component: resourceBundleName)
                    // A resource bundle of versioned bundle framework has "Contents/Resources" directory.
                    try await extractPrivacyInfoIfExists(
                        from: RelativePath(validating: "Contents/Resources/PrivacyInfo.xcprivacy"),
                        in: resourceBundlePath
                    )
                }
            } else {
                try await copyInfoPlist(
                    sourceContext: sourceContext,
                    destinationFrameworkBundlePath: destinationFrameworkBundlePath
                )
                let copiedResourceBundlePath = try await copyResourceBundle(
                    sourceContext: sourceContext,
                    destinationFrameworkBundlePath: destinationFrameworkBundlePath
                )

                if let copiedResourceBundlePath {
                    try await extractPrivacyInfoIfExists(
                        from: RelativePath(validating: "PrivacyInfo.xcprivacy"),
                        in: copiedResourceBundlePath
                    )
                }
            }
        }

        private func copyInfoPlist(
            sourceContext: SourceContext,
            destinationFrameworkBundlePath: AbsolutePath
        ) async throws {
            let sourcePath = sourceContext.frameworkInfoPlistPath
            let destinationPath = destinationFrameworkBundlePath.appending(component: "Info.plist")
            try await fileSystem.copy(from: sourcePath.asURL, to: destinationPath.asURL)
        }

        /// Returns the resulting, copied resource bundle path.
        private func copyResourceBundle(
            sourceContext: SourceContext,
            destinationFrameworkBundlePath: AbsolutePath
        ) async throws -> AbsolutePath? {
            if let sourcePath = sourceContext.resourceBundlePath {
                let destinationPath = destinationFrameworkBundlePath.appending(component: sourcePath.basename)
                try await fileSystem.copy(from: sourcePath.asURL, to: destinationPath.asURL)
                return destinationPath
            } else {
                return nil
            }
        }

        /// Extracts PrivacyInfo.xcprivacy to expected location (if exists in the resource bundle).
        ///
        /// - seealso: https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk#Add-a-privacy-manifest-to-your-framework
        private func extractPrivacyInfoIfExists(
            from relativePrivacyInfoPath: RelativePath,
            in resourceBundlePath: AbsolutePath
        ) async throws {
            let privacyInfoPath = resourceBundlePath.appending(relativePrivacyInfoPath)
            if await fileSystem.exists(privacyInfoPath.asURL) {
                try await fileSystem.move(
                    from: privacyInfoPath.asURL,
                    to: resourceBundlePath.parentDirectory
                        .appending(component: relativePrivacyInfoPath.basename)
                        .asURL
                )
            }
        }
    }
}
