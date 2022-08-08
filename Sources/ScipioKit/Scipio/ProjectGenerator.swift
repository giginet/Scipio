import Foundation
import Xcodeproj
import TSCBasic
import Basics

struct ProjectGenerator {
    private let outputDirectory: AbsolutePath
    private let fileSystem: any FileSystem

    init(outputDirectory: AbsolutePath, fileSystem: any FileSystem = localFileSystem) {
        self.outputDirectory = outputDirectory
        self.fileSystem = fileSystem
    }

    struct Result {
        var project: Xcode.Project
        var projectPath: AbsolutePath
    }

    func generate(for package: Package) throws -> Result {
        let projectPath = outputDirectory.appending(component: "\(package.name).xcodeproj")

        let project = try pbxproj(
            xcodeprojPath: projectPath,
            graph: package.graph,
            extraDirs: [],
            extraFiles: [],
            options: .init(useLegacySchemeGenerator: false),
            fileSystem: fileSystem,
            observabilityScope: observabilitySystem.topScope)

        return .init(project: project, projectPath: projectPath)
    }
}

extension Xcode.Project {
    fileprivate var frameworkTargets: [Xcode.Target] {
        targets.filter { $0.productType == .framework }
    }
}
