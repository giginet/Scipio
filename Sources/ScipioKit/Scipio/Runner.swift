import Foundation
import TSCBasic

public struct Runner {
    public init() { }

    public func run(packageDirectory: URL) throws {
        let package = try Package(packageDirectory: packageDirectory)

        let destination = AbsolutePath("/Users/jp30698/work/xcframeworks")

        let generator = ProjectGenerator()
        let project = try generator.generate(for: package, to: destination)
        print(destination)
        print(project)
    }
}
