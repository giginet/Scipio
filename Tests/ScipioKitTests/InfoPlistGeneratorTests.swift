import Foundation
import Testing
@testable import ScipioKit

struct InfoPlistGeneratorTests {
    let fileSystem: LocalFileSystem = .default

    @Test(.temporaryDirectory)
    func generateForBundle() throws {
        let generator = InfoPlistGenerator(fileSystem: fileSystem)
        let temporaryPath = TemporaryDirectory.url.appending(component: "Info.plist")

        try generator.generateForResourceBundle(at: temporaryPath)

        let infoPlistBodyData = try fileSystem.readFileContents(temporaryPath)
        let infoPlistBody = try #require(String(data: infoPlistBodyData, encoding: .utf8))

        #expect(infoPlistBody == """
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
}
