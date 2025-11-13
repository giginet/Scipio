import Foundation
import PackageManifestKit
import ScipioKitCore

extension PackageResolver {
    struct ModuleTypeResolver {
        let fileSystem: any FileSystem
        let rootPackageDirectory: URL

        let clangFileTypes = ["c", "m", "mm", "cc", "cpp", "cxx"]
        let headerExtensions = ["h", "hh", "hpp", "h++", "hp", "hxx", "H", "ipp", "def"]
        let asmFileTypes = ["s", "S"]
        let swiftFileType = "swift"

        /// Determine module type based on target type and source files.
        func resolve(
            target: Target,
            dependencyPackage: DependencyPackage
        ) -> ResolvedModuleType {
            switch target.type {
            case .binary:
                resolveModuleTypeForBinaryTarget(
                    target,
                    dependencyPackage: dependencyPackage
                )
            default:
                resolveModuleTypeForLibraryTarget(
                    target,
                    dependencyPackage: dependencyPackage
                )
            }
        }

        private func resolveModuleTypeForBinaryTarget(
            _ target: Target,
            dependencyPackage: DependencyPackage
        ) -> ResolvedModuleType {
            assert(target.type == .binary)

            let artifactType: ResolvedModuleType.BinaryArtifactLocation = {
                let artifactsLocation: ResolvedModuleType.BinaryArtifactLocation = .remote(
                    packageIdentity: dependencyPackage.identity,
                    name: target.name
                )
                let artifactsURL = artifactsLocation.artifactURL(rootPackageDirectory: rootPackageDirectory)

                return if fileSystem.exists(artifactsURL) {
                    artifactsLocation
                } else {
                    .local(resolveTargetFullPath(of: target, dependencyPackage: dependencyPackage))
                }
            }()

            return .binary(artifactType)
        }

        private func resolveModuleTypeForLibraryTarget(
            _ target: Target,
            dependencyPackage: DependencyPackage
        ) -> ResolvedModuleType {
            assert(target.type != .binary)

            let moduleFullPath = resolveTargetFullPath(of: target, dependencyPackage: dependencyPackage)
            let moduleSourcesFullPaths = target.sources?.map { moduleFullPath.appending(component: $0) } ?? [moduleFullPath]
            let moduleExcludeFullPaths = target.exclude.map { moduleFullPath.appending(component: $0) }
            let publicHeadersPath = target.publicHeadersPath ?? "include"
            let includeDir = moduleFullPath.appending(component: publicHeadersPath).standardizedFileURL

            let sources: [URL] = moduleSourcesFullPaths.flatMap { source in
                FileManager.default
                    .enumerator(at: source, includingPropertiesForKeys: nil)?
                    .lazy
                    .compactMap { $0 as? URL }
                    .filter { url in
                        moduleExcludeFullPaths.allSatisfy { !url.path.hasPrefix($0.path) }
                    } ?? []
            }

            let hasSwiftSources = sources.contains { $0.pathExtension == swiftFileType }
            let hasClangSources = sources.contains { (clangFileTypes + asmFileTypes).contains($0.pathExtension) }

            // In SwiftPM, the module type (ClangModule or SwiftModule) is determined by checking the file extensions inside the module.
            return if hasSwiftSources && hasClangSources {
                // TODO: Update when SwiftPM supports mixed-language targets.
                // Currently SwiftPM cannot mix Swift and C/Assembly in one target.
                // ref: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0403-swiftpm-mixed-language-targets.md
                fatalError("Mixed-language target are not supported yet.")
            } else if hasSwiftSources {
                .swift
            } else {
                .clang(
                    includeDir: includeDir,
                    publicHeaders: FileManager.default
                        .enumerator(at: includeDir, includingPropertiesForKeys: nil)?
                        .compactMap { $0 as? URL }
                        .filter { headerExtensions.contains($0.pathExtension) }
                        ?? []
                )
            }
        }

        private func resolveTargetFullPath(
            of target: Target,
            dependencyPackage: DependencyPackage
        ) -> URL {
            let packageURL = URL(filePath: dependencyPackage.path)

            // If an explicit path is provided, use it first.
            if let explicitURL = target.path.map({ packageURL.appending(component: $0) }),
               fileSystem.exists(explicitURL) {
                return explicitURL
            }

            // In SwiftPM, if target does not specify a path, it is assumed to be located at one of:
            // - "Sources/<target name>"
            // - "Source/<target name>"
            // - "src/<target name>".
            // - "srcs/<target name>".
            let defaultRoots = ["sources", "source", "src", "srcs"]
            let entries = (try? fileSystem.getDirectoryContents(packageURL)) ?? []

            // Match using lowercase comparison since SwiftPM treats these names case-insensitively
            let sourcesURLs = entries.lazy
                .filter { defaultRoots.contains($0.lowercased()) }
                .map { packageURL.appending(component: $0) }
            let moduleURLs = sourcesURLs.map { $0.appending(component: target.name) }

            return if let moduleURL = moduleURLs.first(where: { fileSystem.exists($0) }) {
                moduleURL
            }
            // If no nested module directory is found but exactly one default root exists
            // (e.g. only Source/xxx.swift in the package), allow that root itself as the module path.
            else if let sourceURL = sourcesURLs.first(where: { fileSystem.exists($0) }) {
                sourceURL
            } else {
                preconditionFailure("Cannot find module directory for target '\(target.name)'")
            }
        }
    }
}
