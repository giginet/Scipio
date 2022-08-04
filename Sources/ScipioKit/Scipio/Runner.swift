import Foundation
import TSCBasic

public struct Runner {
    public init() { }

    public func run(packageDirectory: URL) async throws {
        let package = try Package(packageDirectory: packageDirectory)

        let destination = AbsolutePath("/Users/jp30698/work/xcframeworks")

        let generator = ProjectGenerator(outputDirectory: destination)

        let generationResult = try generator.generate(for: package)
        print(package.graph.packages)
//        let compiler = Compiler<ProcessExecutor>(projectPath: generationResult.projectPath)
//        try await compiler.build(package: package)
    }
}
