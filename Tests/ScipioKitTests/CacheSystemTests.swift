import Foundation
@testable import ScipioKit
import XCTest

final class ClangCheckerTests: XCTestCase {
    private let clangVersion = """
Apple clang version 14.0.0 (clang-1400.0.29.102)
Target: arm64-apple-darwin21.6.0
Thread model: posix
InstalledDir: /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin
"""
    private let customModuleMap = """
    framework module MyTarget {
        umbrella header "umbrella.h"
        export *
    }
    """.data(using: .utf8)!

    func testParseClangVersion() async throws {
        let hook = { arguments in
            XCTAssertEqual(arguments, ["/usr/bin/xcrun", "clang", "--version"])
            return StubbableExecutorResult(arguments: arguments, success: self.clangVersion)
        }
        let clangParser = ClangChecker(executor: StubbableExecutor(executeHook: hook))
        let version = try await clangParser.fetchClangVersion()
        XCTAssertEqual(version, "clang-1400.0.29.102")
    }

    func testEncodeCacheKey() throws {
        let cacheKey = SwiftPMCacheKey(targetName: "MyTarget",
                                       pin: .revision("111111111"),
                                       buildOptions: .init(buildConfiguration: .release,
                                                           isDebugSymbolsEmbedded: false,
                                                           frameworkType: .dynamic,
                                                           sdks: [.iOS],
                                                           extraFlags: .init(swiftFlags: ["-D", "SOME_FLAG"]),
                                                           extraBuildParameters: ["SWIFT_OPTIMIZATION_LEVEL": "-Osize"],
                                                           enableLibraryEvolution: true,
                                                           customFrameworkModuleMapContents: customModuleMap
                                                          ),
                                       clangVersion: "clang-1400.0.29.102",
                                       xcodeVersion: .init(xcodeVersion: "15.4", xcodeBuildVersion: "15F31d")
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(cacheKey)
        let rawString = try XCTUnwrap(String(decoding: data, as: UTF8.self))
        let expected = """
{
  "buildOptions" : {
    "buildConfiguration" : "release",
    "customFrameworkModuleMapContents" : "ZnJhbWV3b3JrIG1vZHVsZSBNeVRhcmdldCB7CiAgICB1bWJyZWxsYSBoZWFkZXIgInVtYnJlbGxhLmgiCiAgICBleHBvcnQgKgp9",
    "enableLibraryEvolution" : true,
    "extraBuildParameters" : {
      "SWIFT_OPTIMIZATION_LEVEL" : "-Osize"
    },
    "extraFlags" : {
      "swiftFlags" : [
        "-D",
        "SOME_FLAG"
      ]
    },
    "frameworkType" : "dynamic",
    "isDebugSymbolsEmbedded" : false,
    "sdks" : [
      "iOS"
    ]
  },
  "clangVersion" : "clang-1400.0.29.102",
  "pin" : {
    "revision" : "111111111"
  },
  "targetName" : "MyTarget",
  "xcodeVersion" : {
    "xcodeBuildVersion" : "15F31d",
    "xcodeVersion" : "15.4"
  }
}
"""
        XCTAssertEqual(rawString, expected)
    }
}
