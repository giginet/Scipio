import Foundation
import ScipioKit

let runner = Runner()
let packageDirectory = URL(fileURLWithPath: "/Users/jp30698/work/xcframeworks/test-package")
try! runner.run(packageDirectory: packageDirectory)
