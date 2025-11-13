import Logging

actor LoggingTestHelper {
    static let shared = LoggingTestHelper()

    var isBootstrapped: Bool = false

    private init() {}

    func bootstrap() {
        if !isBootstrapped {
            LoggingSystem.bootstrap { _ in SwiftLogNoOpLogHandler() }
            isBootstrapped = true
        }
    }
}
