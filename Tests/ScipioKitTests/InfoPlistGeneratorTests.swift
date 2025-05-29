import Foundation
import Testing
@testable import ScipioKit
import Basics

@Suite
struct InfoPlistGeneratorTests {
    let fileSystem = localFileSystem
    
    @Test
    func generateForBundle() throws {
        let generator = InfoPlistGenerator(fileSystem: fileSystem)
        let temporaryPath = try fileSystem
            .tempDirectory
            .appending(components: "Info.plist")
        defer { try? fileSystem.removeFileTree(temporaryPath) }
        try generator.generateForResourceBundle(at: temporaryPath.scipioAbsolutePath)

        let infoPlistBody = try fileSystem.readFileContents(temporaryPath).cString

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
