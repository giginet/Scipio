import Foundation
import Xcodeproj
import TSCBasic
import Basics

struct ProjectGenerator {
    private let outputDirectory: AbsolutePath
    private let fileSystem: any FileSystem

    init(outputDirectory: AbsolutePath, fileSystem: any FileSystem = LocalFileSystem()) {
        self.outputDirectory = outputDirectory
        self.fileSystem = fileSystem
    }

    struct Result {
        var project: Xcode.Project
        var projectPath: AbsolutePath
    }

    func generate(for package: Package) throws -> Result {
        let observabilitySystem = ObservabilitySystem { _, diagnostics in
            print("\(diagnostics.severity): \(diagnostics.message)")
        }

        let projectPath = outputDirectory.appending(component: "\(package.name).xcodeproj")

        let project = try Xcodeproj.generate(
            projectName: package.name,
            xcodeprojPath: projectPath,
            graph: package.graph,
            options: .init(),
            fileSystem: fileSystem,
            observabilityScope: observabilitySystem.topScope)
        

        let distributionXCConfig = RelativePath("Distribution.xcconfig")
        try fileSystem.writeFileContents(AbsolutePath(outputDirectory, distributionXCConfig),
                                         string: distributionXCConfigContents)

        let group = createOrGetConfigsGroup(project: project)
        let reference = group.addFileReference (
            path: distributionXCConfig.pathString,
            name: distributionXCConfig.basename
        )

        for target in project.targets {
            target.buildSettings.xcconfigFileRef = reference
        }

        for target in project.frameworkTargets {
            let name = "\(target.name.spm_mangledToC99ExtendedIdentifier())_Info.plist"
            let path = projectPath.appending(RelativePath(name))
            try fileSystem.writeFileContents(path) { stream in
                stream.write(infoPlist)
            }
        }

        return .init(project: project, projectPath: projectPath)
    }

    private var distributionXCConfigContents: String {
        """
        BUILD_LIBRARY_FOR_DISTRIBUTION=YES
        """
    }

    private var infoPlist: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
        <key>CFBundleDevelopmentRegion</key>
        <string>en</string>
        <key>CFBundleExecutable</key>
        <string>$(EXECUTABLE_NAME)</string>
        <key>CFBundleIdentifier</key>
        <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
        <key>CFBundleInfoDictionaryVersion</key>
        <string>6.0</string>
        <key>CFBundleName</key>
        <string>$(PRODUCT_NAME)</string>
        <key>CFBundlePackageType</key>
        <string>FMWK</string>
        <key>CFBundleShortVersionString</key>
        <string>1.0</string>
        <key>CFBundleSignature</key>
        <string>????</string>
        <key>CFBundleVersion</key>
        <string>$(CURRENT_PROJECT_VERSION)</string>
        <key>NSPrincipalClass</key>
        <string></string>
        </dict>
        </plist>
        """
    }

    private func createOrGetConfigsGroup(project: Xcode.Project) -> Xcode.Group {
        let name = "Configs"

        if let group = project.mainGroup.subitems.lazy.compactMap({ $0 as? Xcode.Group }).first(where: { $0.name == name }) {
            return group
        }

        return project.mainGroup.addGroup(path: "", name: name)
    }
}

extension Xcode.Project {
    fileprivate var frameworkTargets: [Xcode.Target] {
        targets.filter { $0.productType == .framework }
    }
}
