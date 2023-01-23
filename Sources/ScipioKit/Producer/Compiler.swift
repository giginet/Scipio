import Foundation
import PackageGraph

protocol Compiler {
    func createXCFramework(target: ResolvedTarget,
                           outputDirectory: URL,
                           overwrite: Bool) async throws
}
