import Logging

/// A helper actor that ensures `LoggingSystem.bootstrap` is called only once.
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
