// ===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
// ===----------------------------------------------------------------------===//
//
// NOTE: This file has been modified from the original version.
//
// ===----------------------------------------------------------------------===//

import Foundation
import TSCBasic

/// Name of the module map file recognized by the Clang and Swift compilers.
extension URL {
  fileprivate var moduleEscapedPathString: String {
      absoluteString.replacingOccurrences(of: "\\", with: "\\\\")
  }
}

struct ModuleMapGenerator {
    private let moduleMapFilename = "module.modulemap"
    /// The name of the Clang target (for diagnostics).
    private let targetName: String

    /// The module name of the target.
    private let moduleName: String

    /// The target's public-headers directory.
    private let publicHeadersDir: URL

    /// The file system to be used.
    private let fileSystem: any FileSystem

    init(targetName: String, moduleName: String, publicHeadersDir: URL, fileSystem: some FileSystem) {
        self.targetName = targetName
        self.moduleName = moduleName
        self.publicHeadersDir = publicHeadersDir
        self.fileSystem = fileSystem
    }

    /// Inspects the file system at the public-headers directory with which the module map generator was instantiated, and returns the type of module map that applies to that directory.  This function contains all of the heuristics that implement module map policy for package targets; other functions just use the results of this determination.
    func determineModuleMapType() -> ModuleMapType {
        // First check for a custom module map.
        let customModuleMapFile = publicHeadersDir.appending(component: moduleMapFilename)
        if fileSystem.isFile(customModuleMapFile) {
            return .custom(customModuleMapFile)
        }

        // Warn if the public-headers directory is missing.  For backward compatibility reasons, this is not an error, we just won't generate a module map in that case.
        guard fileSystem.exists(publicHeadersDir) else {
            return .none
        }

        // Next try to get the entries in the public-headers directory.
        let entries: Set<URL>
        do {
            let array = try fileSystem.getDirectoryContents(publicHeadersDir)
                .map({ publicHeadersDir.appending(component: $0) })
            entries = Set(array)
        } catch {
            // This might fail because of a file system error, etc.
            return .none
        }

        // Filter out headers and directories at the top level of the public-headers directory.
        // FIXME: What about .hh files, or .hpp, etc?  We should centralize the detection of file types based on names (and ideally share with SwiftDriver).
        let headers = entries.filter({ fileSystem.isFile($0) && $0.pathExtension == "h" })
        let directories = entries.filter({ fileSystem.isDirectory($0) })

        // If 'PublicHeadersDir/ModuleName.h' exists, then use it as the umbrella header.
        let umbrellaHeader = publicHeadersDir.appending(component: moduleName + ".h")
        if fileSystem.isFile(umbrellaHeader) {
            // In this case, 'PublicHeadersDir' is expected to contain no subdirectories.
            if directories.count != 0 {
                return .none
            }
            return .umbrellaHeader(umbrellaHeader)
        }

        // If 'PublicHeadersDir/ModuleName/ModuleName.h' exists, then use it as the umbrella header.
        let nestedUmbrellaHeader = publicHeadersDir.appending(components: moduleName, moduleName + ".h")
        if fileSystem.isFile(nestedUmbrellaHeader) {
            // In this case, 'PublicHeadersDir' is expected to contain no subdirectories other than 'ModuleName'.
            if directories.count != 1 {
                return .none
            }
            // In this case, 'PublicHeadersDir' is also expected to contain no header files.
            if headers.count != 0 {
                return .none
            }
            return .umbrellaHeader(nestedUmbrellaHeader)
        }

        // Otherwise, if 'PublicHeadersDir' contains only header files and no subdirectories, use it as the umbrella directory.
        if headers.count == entries.count {
            return .umbrellaDirectory(publicHeadersDir)
        }

        // Otherwise, the module's headers are considered to be incompatible with modules.  Per the original design, though, an umbrella directory is still created for them.  This will lead to build failures if those headers are included and they are not compatible with modules.  A future evolution proposal should revisit these semantics, especially to make it easier to existing wrap C source bases that are incompatible with modules.
        return .umbrellaDirectory(publicHeadersDir)
    }
}

/// A type of module map to generate.
enum GeneratedModuleMapType {
    case umbrellaHeader(URL)
    case umbrellaDirectory(URL)
}

extension ModuleMapType {
    /// Returns the type of module map to generate for this kind of module map, or nil to not generate one at all.
    var generatedModuleMapType: GeneratedModuleMapType? {
        switch self {
        case .umbrellaHeader(let path): return .umbrellaHeader(path)
        case .umbrellaDirectory(let path): return .umbrellaDirectory(path)
        case .none, .custom: return nil
        }
    }
}

enum ModuleMapType: Equatable {
    /// No module map file.
    case none
    /// A custom module map file.
    case custom(URL)
    /// An umbrella header included by a generated module map file.
    case umbrellaHeader(URL)
    /// An umbrella directory included by a generated module map file.
    case umbrellaDirectory(URL)
}
