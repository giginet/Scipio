import Testing
@testable import ScipioKit

let fixture = ###"""
[
  {
    "contents" : {
      "guid" : "Workspace:/Users/giginet/work/Swift/swift-build-sandbox/MyFramework@11",
      "name" : "MyFramework",
      "path" : "/Users/giginet/work/Swift/swift-build-sandbox/MyFramework",
      "projects" : [
        "02f7d20314be93eb12e409692a5612f338321df572c6693a07804764562f9103",
        "732b7561e6c63edef06f50fd6c5154e18ec8b275bfef97e3ac34f7ceb7d8bd4a"
      ]
    },
    "signature" : "c8dcfaec9093de73235ac136db007773aee9abb11afa362752b5013744d2e20b",
    "type" : "workspace"
  },
  {
    "contents" : {
      "buildConfigurations" : [
        {
          "buildSettings" : {
            "CLANG_ENABLE_OBJC_ARC" : "YES",
            "CODE_SIGNING_REQUIRED" : "NO",
            "CODE_SIGN_IDENTITY" : "",
            "COPY_PHASE_STRIP" : "NO",
            "DEBUG_INFORMATION_FORMAT" : "dwarf",
            "DRIVERKIT_DEPLOYMENT_TARGET" : "19.0",
            "DYLIB_INSTALL_NAME_BASE" : "@rpath",
            "ENABLE_NS_ASSERTIONS" : "YES",
            "ENABLE_TESTABILITY" : "YES",
            "ENABLE_TESTING_SEARCH_PATHS" : "YES",
            "ENTITLEMENTS_REQUIRED" : "NO",
            "FRAMEWORK_SEARCH_PATHS[__platform_filter=ios;ios-simulator]" : [
              "$(inherited)",
              "$(PLATFORM_DIR)/Developer/Library/Frameworks"
            ],
            "FRAMEWORK_SEARCH_PATHS[__platform_filter=macos]" : [
              "$(inherited)",
              "$(PLATFORM_DIR)/Developer/Library/Frameworks"
            ],
            "FRAMEWORK_SEARCH_PATHS[__platform_filter=tvos;tvos-simulator]" : [
              "$(inherited)",
              "$(PLATFORM_DIR)/Developer/Library/Frameworks"
            ],
            "GCC_OPTIMIZATION_LEVEL" : "0",
            "GCC_PREPROCESSOR_DEFINITIONS" : [
              "$(inherited)",
              "SWIFT_PACKAGE",
              "DEBUG=1"
            ],
            "IPHONEOS_DEPLOYMENT_TARGET" : "12.0",
            "IPHONEOS_DEPLOYMENT_TARGET[__platform_filter=ios-maccatalyst]" : "13.0",
            "KEEP_PRIVATE_EXTERNS" : "NO",
            "MACOSX_DEPLOYMENT_TARGET" : "10.13",
            "ONLY_ACTIVE_ARCH" : "YES",
            "OTHER_LDRFLAGS" : [

            ],
            "PRODUCT_NAME" : "$(TARGET_NAME)",
            "SDKROOT" : "auto",
            "SDK_VARIANT" : "auto",
            "SKIP_INSTALL" : "YES",
            "SUPPORTED_PLATFORMS" : [
              "$(AVAILABLE_PLATFORMS)"
            ],
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS" : [
              "$(inherited)",
              "SWIFT_PACKAGE",
              "DEBUG"
            ],
            "SWIFT_INSTALL_OBJC_HEADER" : "NO",
            "SWIFT_OBJC_INTERFACE_HEADER_NAME" : "",
            "SWIFT_OPTIMIZATION_LEVEL" : "-Onone",
            "TVOS_DEPLOYMENT_TARGET" : "12.0",
            "USE_HEADERMAP" : "NO",
            "WATCHOS_DEPLOYMENT_TARGET" : "4.0",
            "XROS_DEPLOYMENT_TARGET" : "1.0"
          },
          "guid" : "PACKAGE:/Users/giginet/work/Swift/swift-build-sandbox/MyFramework::BUILDCONFIG_Debug",
          "impartedBuildProperties" : {
            "buildSettings" : {

            }
          },
          "name" : "Debug"
        },
        {
          "buildSettings" : {
            "CLANG_ENABLE_OBJC_ARC" : "YES",
            "CODE_SIGNING_REQUIRED" : "NO",
            "CODE_SIGN_IDENTITY" : "",
            "COPY_PHASE_STRIP" : "YES",
            "DEBUG_INFORMATION_FORMAT" : "dwarf-with-dsym",
            "DRIVERKIT_DEPLOYMENT_TARGET" : "19.0",
            "DYLIB_INSTALL_NAME_BASE" : "@rpath",
            "ENABLE_TESTABILITY" : "YES",
            "ENABLE_TESTING_SEARCH_PATHS" : "YES",
            "ENTITLEMENTS_REQUIRED" : "NO",
            "FRAMEWORK_SEARCH_PATHS[__platform_filter=ios;ios-simulator]" : [
              "$(inherited)",
              "$(PLATFORM_DIR)/Developer/Library/Frameworks"
            ],
            "FRAMEWORK_SEARCH_PATHS[__platform_filter=macos]" : [
              "$(inherited)",
              "$(PLATFORM_DIR)/Developer/Library/Frameworks"
            ],
            "FRAMEWORK_SEARCH_PATHS[__platform_filter=tvos;tvos-simulator]" : [
              "$(inherited)",
              "$(PLATFORM_DIR)/Developer/Library/Frameworks"
            ],
            "GCC_OPTIMIZATION_LEVEL" : "s",
            "GCC_PREPROCESSOR_DEFINITIONS" : [
              "$(inherited)",
              "SWIFT_PACKAGE"
            ],
            "IPHONEOS_DEPLOYMENT_TARGET" : "12.0",
            "IPHONEOS_DEPLOYMENT_TARGET[__platform_filter=ios-maccatalyst]" : "13.0",
            "KEEP_PRIVATE_EXTERNS" : "NO",
            "MACOSX_DEPLOYMENT_TARGET" : "10.13",
            "OTHER_LDRFLAGS" : [

            ],
            "PRODUCT_NAME" : "$(TARGET_NAME)",
            "SDKROOT" : "auto",
            "SDK_VARIANT" : "auto",
            "SKIP_INSTALL" : "YES",
            "SUPPORTED_PLATFORMS" : [
              "$(AVAILABLE_PLATFORMS)"
            ],
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS" : [
              "$(inherited)",
              "SWIFT_PACKAGE"
            ],
            "SWIFT_INSTALL_OBJC_HEADER" : "NO",
            "SWIFT_OBJC_INTERFACE_HEADER_NAME" : "",
            "SWIFT_OPTIMIZATION_LEVEL" : "-Owholemodule",
            "TVOS_DEPLOYMENT_TARGET" : "12.0",
            "USE_HEADERMAP" : "NO",
            "WATCHOS_DEPLOYMENT_TARGET" : "4.0",
            "XROS_DEPLOYMENT_TARGET" : "1.0"
          },
          "guid" : "PACKAGE:/Users/giginet/work/Swift/swift-build-sandbox/MyFramework::BUILDCONFIG_Release",
          "impartedBuildProperties" : {
            "buildSettings" : {

            }
          },
          "name" : "Release"
        }
      ],
      "defaultConfigurationName" : "Release",
      "developmentRegion" : "en",
      "groupTree" : {
        "children" : [
          {
            "children" : [
              {
                "fileType" : "sourcecode.swift",
                "guid" : "PACKAGE:/Users/giginet/work/Swift/swift-build-sandbox/MyFramework::MAINGROUP::REF_0::REF_0",
                "name" : "MyFrameworkTests.swift",
                "path" : "MyFrameworkTests.swift",
                "sourceTree" : "<group>",
                "type" : "file"
              }
            ],
            "guid" : "PACKAGE:/Users/giginet/work/Swift/swift-build-sandbox/MyFramework::MAINGROUP::REF_0",
            "name" : "Tests/MyFrameworkTests",
            "path" : "Tests/MyFrameworkTests",
            "sourceTree" : "<group>",
            "type" : "group"
          },
          {
            "children" : [
              {
                "fileType" : "sourcecode.swift",
                "guid" : "PACKAGE:/Users/giginet/work/Swift/swift-build-sandbox/MyFramework::MAINGROUP::REF_1::REF_0",
                "name" : "MyFramework.swift",
                "path" : "MyFramework.swift",
                "sourceTree" : "<group>",
                "type" : "file"
              }
            ],
            "guid" : "PACKAGE:/Users/giginet/work/Swift/swift-build-sandbox/MyFramework::MAINGROUP::REF_1",
            "name" : "Sources/MyFramework",
            "path" : "Sources/MyFramework",
            "sourceTree" : "<group>",
            "type" : "group"
          }
        ],
        "guid" : "PACKAGE:/Users/giginet/work/Swift/swift-build-sandbox/MyFramework::MAINGROUP",
        "name" : "",
        "path" : "",
        "sourceTree" : "<group>",
        "type" : "group"
      },
      "guid" : "PACKAGE:/Users/giginet/work/Swift/swift-build-sandbox/MyFramework@11",
      "path" : "/Users/giginet/work/Swift/swift-build-sandbox/MyFramework",
      "projectDirectory" : "/Users/giginet/work/Swift/swift-build-sandbox/MyFramework",
      "projectIsPackage" : "true",
      "projectName" : "MyFramework",
      "targets" : [
        "66e091fddbf2087e7b06a92ef03e47ac6ad6eef82970a98530df3bd397dafebe",
        "1c930c5264e92d6202de1324c4175b2d8cba3f43de02449f4135fd6673f76982",
        "6436ee11dd242bedc1b178d0182c6a5ad6f98c17aba102740b4a305c7d7eb9e8"
      ]
    },
    "signature" : "02f7d20314be93eb12e409692a5612f338321df572c6693a07804764562f9103",
    "type" : "project"
  },
  {
    "contents" : {
      "buildConfigurations" : [
        {
          "buildSettings" : {
            "APPLICATION_EXTENSION_API_ONLY" : "YES",
            "USES_SWIFTPM_UNSAFE_FLAGS" : "NO"
          },
          "guid" : "PACKAGE-PRODUCT:MyFramework::BUILDCONFIG_Debug",
          "impartedBuildProperties" : {
            "buildSettings" : {

            }
          },
          "name" : "Debug"
        },
        {
          "buildSettings" : {
            "APPLICATION_EXTENSION_API_ONLY" : "YES",
            "USES_SWIFTPM_UNSAFE_FLAGS" : "NO"
          },
          "guid" : "PACKAGE-PRODUCT:MyFramework::BUILDCONFIG_Release",
          "impartedBuildProperties" : {
            "buildSettings" : {

            }
          },
          "name" : "Release"
        }
      ],
      "dependencies" : [
        {
          "guid" : "PACKAGE-TARGET:MyFramework@11"
        }
      ],
      "frameworksBuildPhase" : {
        "buildFiles" : [
          {
            "guid" : "PACKAGE-PRODUCT:MyFramework::BUILDPHASE_0::0",
            "platformFilters" : [

            ],
            "targetReference" : "PACKAGE-TARGET:MyFramework@11"
          }
        ],
        "guid" : "PACKAGE-PRODUCT:MyFramework::BUILDPHASE_0",
        "type" : "com.apple.buildphase.frameworks"
      },
      "guid" : "PACKAGE-PRODUCT:MyFramework@11",
      "name" : "MyFramework_6B1018121018B67F_PackageProduct",
      "type" : "packageProduct"
    },
    "signature" : "66e091fddbf2087e7b06a92ef03e47ac6ad6eef82970a98530df3bd397dafebe",
    "type" : "target"
  },
  {
    "contents" : {
      "buildConfigurations" : [
        {
          "buildSettings" : {
            "CLANG_ENABLE_MODULES" : "YES",
            "DEFINES_MODULE" : "YES",
            "EXECUTABLE_NAME" : "MyFrameworkTests",
            "GENERATE_INFOPLIST_FILE" : "YES",
            "IPHONEOS_DEPLOYMENT_TARGET" : "13.0",
            "LD_RUNPATH_SEARCH_PATHS" : [
              "$(inherited)",
              "@loader_path/Frameworks",
              "@loader_path/../Frameworks"
            ],
            "LIBRARY_SEARCH_PATHS" : [
              "$(inherited)",
              "/Applications/Xcode-16.2.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx"
            ],
            "MACOSX_DEPLOYMENT_TARGET" : "13.0",
            "OTHER_SWIFT_FLAGS" : [
              "-package-name",
              "myframework"
            ],
            "PACKAGE_RESOURCE_TARGET_KIND" : "regular",
            "PRODUCT_BUNDLE_IDENTIFIER" : "MyFrameworkTests",
            "PRODUCT_MODULE_NAME" : "MyFrameworkTests",
            "PRODUCT_NAME" : "MyFrameworkTests",
            "SWIFT_VERSION" : "6",
            "TARGET_NAME" : "MyFrameworkTests",
            "TVOS_DEPLOYMENT_TARGET" : "13.0",
            "WATCHOS_DEPLOYMENT_TARGET" : "7.0",
            "XROS_DEPLOYMENT_TARGET" : "1.0"
          },
          "guid" : "PACKAGE-PRODUCT:MyFrameworkTests::BUILDCONFIG_Debug",
          "impartedBuildProperties" : {
            "buildSettings" : {

            }
          },
          "name" : "Debug"
        },
        {
          "buildSettings" : {
            "CLANG_ENABLE_MODULES" : "YES",
            "DEFINES_MODULE" : "YES",
            "EXECUTABLE_NAME" : "MyFrameworkTests",
            "GENERATE_INFOPLIST_FILE" : "YES",
            "IPHONEOS_DEPLOYMENT_TARGET" : "13.0",
            "LD_RUNPATH_SEARCH_PATHS" : [
              "$(inherited)",
              "@loader_path/Frameworks",
              "@loader_path/../Frameworks"
            ],
            "LIBRARY_SEARCH_PATHS" : [
              "$(inherited)",
              "/Applications/Xcode-16.2.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx"
            ],
            "MACOSX_DEPLOYMENT_TARGET" : "13.0",
            "OTHER_SWIFT_FLAGS" : [
              "-package-name",
              "myframework"
            ],
            "PACKAGE_RESOURCE_TARGET_KIND" : "regular",
            "PRODUCT_BUNDLE_IDENTIFIER" : "MyFrameworkTests",
            "PRODUCT_MODULE_NAME" : "MyFrameworkTests",
            "PRODUCT_NAME" : "MyFrameworkTests",
            "SWIFT_VERSION" : "6",
            "TARGET_NAME" : "MyFrameworkTests",
            "TVOS_DEPLOYMENT_TARGET" : "13.0",
            "WATCHOS_DEPLOYMENT_TARGET" : "7.0",
            "XROS_DEPLOYMENT_TARGET" : "1.0"
          },
          "guid" : "PACKAGE-PRODUCT:MyFrameworkTests::BUILDCONFIG_Release",
          "impartedBuildProperties" : {
            "buildSettings" : {

            }
          },
          "name" : "Release"
        }
      ],
      "buildPhases" : [
        {
          "buildFiles" : [
            {
              "fileReference" : "PACKAGE:/Users/giginet/work/Swift/swift-build-sandbox/MyFramework::MAINGROUP::REF_0::REF_0",
              "guid" : "PACKAGE-PRODUCT:MyFrameworkTests::BUILDPHASE_0::0",
              "platformFilters" : [

              ]
            }
          ],
          "guid" : "PACKAGE-PRODUCT:MyFrameworkTests::BUILDPHASE_0",
          "type" : "com.apple.buildphase.sources"
        },
        {
          "buildFiles" : [
            {
              "guid" : "PACKAGE-PRODUCT:MyFrameworkTests::BUILDPHASE_1::0",
              "platformFilters" : [

              ],
              "targetReference" : "PACKAGE-TARGET:MyFramework@11"
            }
          ],
          "guid" : "PACKAGE-PRODUCT:MyFrameworkTests::BUILDPHASE_1",
          "type" : "com.apple.buildphase.frameworks"
        }
      ],
      "buildRules" : [

      ],
      "dependencies" : [
        {
          "guid" : "PACKAGE-TARGET:MyFramework@11"
        }
      ],
      "guid" : "PACKAGE-PRODUCT:MyFrameworkTests@11",
      "impartedBuildProperties" : {
        "buildSettings" : {

        }
      },
      "name" : "MyFrameworkTests_2713FB4B18606497_PackageProduct",
      "productReference" : {
        "guid" : "PRODUCTREF-PACKAGE-PRODUCT:MyFrameworkTests",
        "name" : "MyFrameworkTests",
        "type" : "file"
      },
      "productTypeIdentifier" : "com.apple.product-type.bundle.unit-test",
      "type" : "standard"
    },
    "signature" : "1c930c5264e92d6202de1324c4175b2d8cba3f43de02449f4135fd6673f76982",
    "type" : "target"
  },
  {
    "contents" : {
      "buildConfigurations" : [
        {
          "buildSettings" : {
            "CLANG_COVERAGE_MAPPING_LINKER_ARGS" : "NO",
            "CLANG_ENABLE_MODULES" : "YES",
            "DEFINES_MODULE" : "YES",
            "EXECUTABLE_NAME" : "MyFramework.o",
            "GENERATE_MASTER_OBJECT_FILE" : "NO",
            "MACH_O_TYPE" : "mh_object",
            "MODULEMAP_FILE_CONTENTS" : "module MyFramework {\n    header \"MyFramework-Swift.h\"\n    export *\n}",
            "MODULEMAP_PATH" : "$(OBJROOT)/GeneratedModuleMaps/$(PLATFORM_NAME)/MyFramework.modulemap",
            "OTHER_SWIFT_FLAGS" : [
              "-package-name",
              "myframework"
            ],
            "PACKAGE_RESOURCE_TARGET_KIND" : "regular",
            "PRODUCT_BUNDLE_IDENTIFIER" : "MyFramework",
            "PRODUCT_MODULE_NAME" : "MyFramework",
            "PRODUCT_NAME" : "MyFramework.o",
            "SWIFT_OBJC_INTERFACE_HEADER_DIR" : "$(OBJROOT)/GeneratedModuleMaps/$(PLATFORM_NAME)",
            "SWIFT_OBJC_INTERFACE_HEADER_NAME" : "MyFramework-Swift.h",
            "SWIFT_VERSION" : "6",
            "TARGET_NAME" : "MyFramework"
          },
          "guid" : "PACKAGE-TARGET:MyFramework::BUILDCONFIG_Debug",
          "impartedBuildProperties" : {
            "buildSettings" : {
              "OTHER_CFLAGS" : [
                "$(inherited)",
                "-fmodule-map-file=$(OBJROOT)/GeneratedModuleMaps/$(PLATFORM_NAME)/MyFramework.modulemap"
              ],
              "OTHER_LDFLAGS" : [
                "$(inherited)",
                "-Wl,-no_warn_duplicate_libraries"
              ],
              "OTHER_LDRFLAGS" : [

              ]
            }
          },
          "name" : "Debug"
        },
        {
          "buildSettings" : {
            "CLANG_COVERAGE_MAPPING_LINKER_ARGS" : "NO",
            "CLANG_ENABLE_MODULES" : "YES",
            "DEFINES_MODULE" : "YES",
            "EXECUTABLE_NAME" : "MyFramework.o",
            "GENERATE_MASTER_OBJECT_FILE" : "NO",
            "MACH_O_TYPE" : "mh_object",
            "MODULEMAP_FILE_CONTENTS" : "module MyFramework {\n    header \"MyFramework-Swift.h\"\n    export *\n}",
            "MODULEMAP_PATH" : "$(OBJROOT)/GeneratedModuleMaps/$(PLATFORM_NAME)/MyFramework.modulemap",
            "OTHER_SWIFT_FLAGS" : [
              "-package-name",
              "myframework"
            ],
            "PACKAGE_RESOURCE_TARGET_KIND" : "regular",
            "PRODUCT_BUNDLE_IDENTIFIER" : "MyFramework",
            "PRODUCT_MODULE_NAME" : "MyFramework",
            "PRODUCT_NAME" : "MyFramework.o",
            "SWIFT_OBJC_INTERFACE_HEADER_DIR" : "$(OBJROOT)/GeneratedModuleMaps/$(PLATFORM_NAME)",
            "SWIFT_OBJC_INTERFACE_HEADER_NAME" : "MyFramework-Swift.h",
            "SWIFT_VERSION" : "6",
            "TARGET_NAME" : "MyFramework"
          },
          "guid" : "PACKAGE-TARGET:MyFramework::BUILDCONFIG_Release",
          "impartedBuildProperties" : {
            "buildSettings" : {
              "OTHER_CFLAGS" : [
                "$(inherited)",
                "-fmodule-map-file=$(OBJROOT)/GeneratedModuleMaps/$(PLATFORM_NAME)/MyFramework.modulemap"
              ],
              "OTHER_LDFLAGS" : [
                "$(inherited)",
                "-Wl,-no_warn_duplicate_libraries"
              ],
              "OTHER_LDRFLAGS" : [

              ]
            }
          },
          "name" : "Release"
        }
      ],
      "buildPhases" : [
        {
          "buildFiles" : [
            {
              "fileReference" : "PACKAGE:/Users/giginet/work/Swift/swift-build-sandbox/MyFramework::MAINGROUP::REF_1::REF_0",
              "guid" : "PACKAGE-TARGET:MyFramework::BUILDPHASE_0::0",
              "platformFilters" : [

              ]
            }
          ],
          "guid" : "PACKAGE-TARGET:MyFramework::BUILDPHASE_0",
          "type" : "com.apple.buildphase.sources"
        }
      ],
      "buildRules" : [

      ],
      "dependencies" : [

      ],
      "guid" : "PACKAGE-TARGET:MyFramework@11",
      "impartedBuildProperties" : {
        "buildSettings" : {
          "OTHER_CFLAGS" : [
            "$(inherited)",
            "-fmodule-map-file=$(OBJROOT)/GeneratedModuleMaps/$(PLATFORM_NAME)/MyFramework.modulemap"
          ],
          "OTHER_LDFLAGS" : [
            "$(inherited)",
            "-Wl,-no_warn_duplicate_libraries"
          ],
          "OTHER_LDRFLAGS" : [

          ]
        }
      },
      "name" : "MyFramework",
      "productReference" : {
        "guid" : "PRODUCTREF-PACKAGE-TARGET:MyFramework",
        "name" : "MyFramework.o",
        "type" : "file"
      },
      "productTypeIdentifier" : "com.apple.product-type.objfile",
      "type" : "standard"
    },
    "signature" : "6436ee11dd242bedc1b178d0182c6a5ad6f98c17aba102740b4a305c7d7eb9e8",
    "type" : "target"
  },
  {
    "contents" : {
      "buildConfigurations" : [
        {
          "buildSettings" : {
            "PRODUCT_NAME" : "$(TARGET_NAME)",
            "SDKROOT" : "auto",
            "SDK_VARIANT" : "auto",
            "SKIP_INSTALL" : "YES",
            "SUPPORTED_PLATFORMS" : [
              "$(AVAILABLE_PLATFORMS)"
            ]
          },
          "guid" : "AGGREGATE::BUILDCONFIG_Debug",
          "impartedBuildProperties" : {
            "buildSettings" : {

            }
          },
          "name" : "Debug"
        },
        {
          "buildSettings" : {
            "PRODUCT_NAME" : "$(TARGET_NAME)",
            "SDKROOT" : "auto",
            "SDK_VARIANT" : "auto",
            "SKIP_INSTALL" : "YES",
            "SUPPORTED_PLATFORMS" : [
              "$(AVAILABLE_PLATFORMS)"
            ]
          },
          "guid" : "AGGREGATE::BUILDCONFIG_Release",
          "impartedBuildProperties" : {
            "buildSettings" : {

            }
          },
          "name" : "Release"
        }
      ],
      "defaultConfigurationName" : "Release",
      "developmentRegion" : "en",
      "groupTree" : {
        "children" : [

        ],
        "guid" : "AGGREGATE::MAINGROUP",
        "name" : "",
        "path" : "",
        "sourceTree" : "<group>",
        "type" : "group"
      },
      "guid" : "AGGREGATE@11",
      "path" : "/Users/giginet/work/Swift/swift-build-sandbox/MyFramework",
      "projectDirectory" : "/Users/giginet/work/Swift/swift-build-sandbox/MyFramework",
      "projectIsPackage" : "true",
      "projectName" : "Aggregate",
      "targets" : [
        "373d3fbcd6e9613e223237926febfdf58dd2a6a7e2f1afa5a3c5db9db278d9aa",
        "d34d48f11531e4dd4768d254046410e1b4d9046ad5fb1d2f74c8edc95933d71f"
      ]
    },
    "signature" : "732b7561e6c63edef06f50fd6c5154e18ec8b275bfef97e3ac34f7ceb7d8bd4a",
    "type" : "project"
  },
  {
    "contents" : {
      "buildConfigurations" : [
        {
          "buildSettings" : {

          },
          "guid" : "ALL-EXCLUDING-TESTS::BUILDCONFIG_Debug",
          "impartedBuildProperties" : {
            "buildSettings" : {

            }
          },
          "name" : "Debug"
        },
        {
          "buildSettings" : {

          },
          "guid" : "ALL-EXCLUDING-TESTS::BUILDCONFIG_Release",
          "impartedBuildProperties" : {
            "buildSettings" : {

            }
          },
          "name" : "Release"
        }
      ],
      "buildPhases" : [

      ],
      "dependencies" : [
        {
          "guid" : "PACKAGE-PRODUCT:MyFramework@11"
        },
        {
          "guid" : "PACKAGE-TARGET:MyFramework@11"
        }
      ],
      "guid" : "ALL-EXCLUDING-TESTS@11",
      "impartedBuildProperties" : {
        "buildSettings" : {

        }
      },
      "name" : "AllExcludingTests",
      "type" : "aggregate"
    },
    "signature" : "373d3fbcd6e9613e223237926febfdf58dd2a6a7e2f1afa5a3c5db9db278d9aa",
    "type" : "target"
  },
  {
    "contents" : {
      "buildConfigurations" : [
        {
          "buildSettings" : {

          },
          "guid" : "ALL-INCLUDING-TESTS::BUILDCONFIG_Debug",
          "impartedBuildProperties" : {
            "buildSettings" : {

            }
          },
          "name" : "Debug"
        },
        {
          "buildSettings" : {

          },
          "guid" : "ALL-INCLUDING-TESTS::BUILDCONFIG_Release",
          "impartedBuildProperties" : {
            "buildSettings" : {

            }
          },
          "name" : "Release"
        }
      ],
      "buildPhases" : [

      ],
      "dependencies" : [
        {
          "guid" : "PACKAGE-PRODUCT:MyFramework@11"
        },
        {
          "guid" : "PACKAGE-PRODUCT:MyFrameworkTests@11"
        },
        {
          "guid" : "PACKAGE-TARGET:MyFramework@11"
        }
      ],
      "guid" : "ALL-INCLUDING-TESTS@11",
      "impartedBuildProperties" : {
        "buildSettings" : {

        }
      },
      "name" : "AllIncludingTests",
      "type" : "aggregate"
    },
    "signature" : "d34d48f11531e4dd4768d254046410e1b4d9046ad5fb1d2f74c8edc95933d71f",
    "type" : "target"
  }
]

"""###

struct PIFManipulatorTests {
    @Test
    func updatePIF() throws {
        let jsonData = try #require(fixture.data(using: .utf8))
        let pif = try ScipioPIF(jsonData: jsonData)
        let manipulator = PIFManipulator(pif: pif)
        
        manipulator.updateTargetBuildConfigurations { context in
            var settings = context.buildConfiguration["buildSettings"] as! [String: Any]
            settings["PRODUCT_NAME"] = "NewProductName"
            return settings
        }
        
        let newJSONData = try pif.dump()
        let contents = String(data: newJSONData, encoding: .utf8)!
        print(contents)
    }
}
