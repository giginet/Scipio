import Foundation
import XCTest
@testable import ScipioKit
import TSCBasic

final class InfoPlistGeneratorTests: XCTestCase {
    let fileSystem = LocalFileSystem.default
    lazy var generator = InfoPlistGenerator(fileSystem: fileSystem)
    var temporaryPath: URL!

    override func setUp() async throws {
        try await super.setUp()

        self.temporaryPath = fileSystem
            .tempDirectory
            .appending(components: "Info.plist")
    }

    func testGenerateForBundle() throws {
        try generator.generateForResourceBundle(at: temporaryPath.absolutePath)

        let infoPlistBodyData = try fileSystem.readFileContents(temporaryPath)
        let infoPlistBody = String(data: infoPlistBodyData, encoding: .utf8)!

        XCTAssertEqual(infoPlistBody, """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleDevelopmentRegion</key>
            <string>$(DEVELOPMENT_LANGUAGE)</string>
            <key>CFBundleIdentifier</key>
            <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
            <key>CFBundleInfoDictionaryVersion</key>
            <string>6.0</string>
            <key>CFBundleName</key>
            <string>$(PRODUCT_NAME)</string>
            <key>CFBundlePackageType</key>
            <string>BNDL</string>
            <key>CFBundleShortVersionString</key>
            <string>1.0</string>
            <key>CFBundleVersion</key>
            <string>1</string>
        </dict>
        </plist>
        """)
    }

    override func tearDown() async throws {
        try await super.tearDown()

        try fileSystem.removeFileTree(temporaryPath)
    }
}
