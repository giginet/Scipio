import Foundation

/// A assembler to generate framework bundle
/// This assembler just relocates framework components into the framework structure
struct FrameworkBundleAssembler {
    private let frameworkComponents: FrameworkComponents
    private let keepPublicHeadersStructure: Bool
    private let outputDirectory: URL
    private let fileSystem: any FileSystem
    private let headerIncludeRewriter: CHeaderIncludeRewriter?

    private var frameworkBundlePath: URL {
        outputDirectory.appending(component: "\(frameworkComponents.frameworkName).framework")
    }

    init(
        frameworkComponents: FrameworkComponents,
        keepPublicHeadersStructure: Bool,
        outputDirectory: URL,
        fileSystem: some FileSystem,
        headerIncludeRewriter: CHeaderIncludeRewriter? = nil
    ) {
        self.frameworkComponents = frameworkComponents
        self.keepPublicHeadersStructure = keepPublicHeadersStructure
        self.outputDirectory = outputDirectory
        self.fileSystem = fileSystem
        self.headerIncludeRewriter = headerIncludeRewriter
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

        return frameworkBundlePath
    }

    private func copyBinary() throws {
        let sourcePath = frameworkComponents.binaryPath
        let destinationPath = frameworkBundlePath.appending(component: frameworkComponents.frameworkName)
        if fileSystem.isSymlink(sourcePath) {
            // Frameworks for macOS have Versions. So their binaries are symlinks
            // Follow symlink to copy a original binary
            let sourceURL = sourcePath
            try fileSystem.copy(
                from: sourceURL.resolvingSymlinksInPath(),
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
            let destinationComponents = Self.headerDestinationComponents(
                header: header,
                includeDir: frameworkComponents.includeDir,
                keepPublicHeadersStructure: keepPublicHeadersStructure
            )
            let destination = headerDir.appending(components: destinationComponents)
            if destinationComponents.count > 1 {
                try fileSystem.createDirectory(
                    destination.deletingLastPathComponent(),
                    recursive: true
                )
            }
            try copyHeader(from: header, to: destination)
        }
    }

    /// Path components below `Headers/`; shared with `CHeaderIncludeRewriter`.
    static func headerDestinationComponents(
        header: URL,
        includeDir: URL?,
        keepPublicHeadersStructure: Bool
    ) -> [String] {
        guard keepPublicHeadersStructure, let includeDir else {
            return [header.lastPathComponent]
        }
        var base = includeDir.standardizedFileURL.path(percentEncoded: false)
        if base.hasSuffix("/") && base != "/" {
            base.removeLast()
        }
        let parent = header.dirname
        guard parent == base || parent.hasPrefix(base + "/") else {
            return [header.lastPathComponent]
        }
        let subdirectoryComponents = parent.dropFirst(base.count)
            .split(separator: "/")
            .map(String.init)
        return subdirectoryComponents + [header.lastPathComponent]
    }

    /// Copies a public header, rewriting textual headers when a rewriter is configured.
    private func copyHeader(from source: URL, to destination: URL) throws {
        // `fileSystem.copy` refuses to overwrite, but `writeFileContents` does not: check upfront so
        // headers flattened to a colliding name keep failing loudly on either path.
        guard !fileSystem.exists(destination) else {
            throw FileSystemError.alreadyExistsAtDestination(path: destination)
        }

        guard let headerIncludeRewriter, !headerIncludeRewriter.isEmpty else {
            try fileSystem.copy(from: source, to: destination)
            return
        }

        let rawData = try fileSystem.readFileContents(source)
        guard let contents = String(bytes: rawData, encoding: .utf8) else {
            try fileSystem.copy(from: source, to: destination)
            return
        }

        try fileSystem.writeFileContents(destination, string: headerIncludeRewriter.rewrite(contents))
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
                to: modulesDir.appending(component: swiftModulesPath.lastPathComponent)
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
            let frameworkBundlePath: URL
            let frameworkInfoPlistPath: URL
            let resourceBundlePath: URL?
        }

        private let fileSystem: any FileSystem

        init(fileSystem: some FileSystem) {
            self.fileSystem = fileSystem
        }

        func copyResources(
            sourceContext: SourceContext,
            destinationFrameworkBundlePath: URL
        ) throws {
            if sourceContext.isFrameworkVersionedBundle {
                // The framework is a versioned bundle, so copy entire Resources directory
                // instead of copying its Info.plist and resource bundle separately.
                let sourceResourcesPath = sourceContext.frameworkBundlePath.appending(component: "Resources")
                let destinationResourcesPath = destinationFrameworkBundlePath.appending(component: "Resources")
                try fileSystem.copy(
                    from: sourceResourcesPath.resolvingSymlinksInPath(),
                    to: destinationResourcesPath
                )

                if let resourceBundleName = sourceContext.resourceBundlePath?.lastPathComponent {
                    let resourceBundlePath = destinationResourcesPath.appending(component: resourceBundleName)
                    // A resource bundle of versioned bundle framework has "Contents/Resources" directory.
                    try extractPrivacyInfoIfExists(
                        from: "Contents", "Resources", "PrivacyInfo.xcprivacy",
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
                        from: "PrivacyInfo.xcprivacy",
                        in: copiedResourceBundlePath
                    )
                }
            }
        }

        private func copyInfoPlist(
            sourceContext: SourceContext,
            destinationFrameworkBundlePath: URL
        ) throws {
            let sourcePath = sourceContext.frameworkInfoPlistPath
            let destinationPath = destinationFrameworkBundlePath.appending(component: "Info.plist")
            try fileSystem.copy(from: sourcePath, to: destinationPath)
        }

        /// Returns the resulting, copied resource bundle path.
        private func copyResourceBundle(
            sourceContext: SourceContext,
            destinationFrameworkBundlePath: URL
        ) throws -> URL? {
            if let sourcePath = sourceContext.resourceBundlePath {
                let destinationPath = destinationFrameworkBundlePath.appending(component: sourcePath.lastPathComponent)
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
            from relativePrivacyInfoPathComponents: String...,
            in resourceBundlePath: URL,
        ) throws {
            let privacyInfoPath = resourceBundlePath.appending(components: relativePrivacyInfoPathComponents)
            if fileSystem.exists(privacyInfoPath) {
                try fileSystem.move(
                    from: privacyInfoPath,
                    to: resourceBundlePath.parentDirectory
                        .appending(component: privacyInfoPath.lastPathComponent)
                )
            }
        }
    }
}
