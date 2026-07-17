import Foundation

struct InfoPlistGenerator {
    private let fileSystem: any FileSystem

    init(fileSystem: any FileSystem) {
        self.fileSystem = fileSystem
    }

    func generateForResourceBundle(at path: URL) throws {
        let body = resourceBundleBody
        try fileSystem.writeFileContents(path, string: body)
    }

    /// Generates an Info.plist for framework bundles assembled without a build step,
    /// so all values are concrete instead of build-setting placeholders.
    func generateForFramework(name: String, bundleIdentifier: String, at path: URL) throws {
        try fileSystem.writeFileContents(path, string: frameworkBody(name: name, bundleIdentifier: bundleIdentifier))
    }

    private func frameworkBody(name: String, bundleIdentifier: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleDevelopmentRegion</key>
            <string>en</string>
            <key>CFBundleExecutable</key>
            <string>\(name)</string>
            <key>CFBundleIdentifier</key>
            <string>\(bundleIdentifier)</string>
            <key>CFBundleInfoDictionaryVersion</key>
            <string>6.0</string>
            <key>CFBundleName</key>
            <string>\(name)</string>
            <key>CFBundlePackageType</key>
            <string>FMWK</string>
            <key>CFBundleShortVersionString</key>
            <string>1.0</string>
            <key>CFBundleVersion</key>
            <string>1</string>
        </dict>
        </plist>
        """
    }

    private var resourceBundleBody: String {
        """
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
        """
    }
}
