import Foundation
import ScipioKit

let semaphore = DispatchSemaphore(value: 0)

let runner = Runner()

let packageDirectory = URL(fileURLWithPath: "/Users/jp30698/work/xcframeworks/test-package")

Task {
    try await runner.run(packageDirectory: packageDirectory)
    semaphore.signal()
}

semaphore.wait()
