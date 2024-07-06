import Foundation
import PackagePlugin

@main
struct GenerateScipioVersion: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let zshPath = URL(filePath: "/bin/zsh")
        
        #if compiler(>=6.0)
        let generatedSourceDir = context.pluginWorkDirectoryURL
        #else
        let generatedSourceDir = URL(filePath: context.pluginWorkDirectory.string)
        #endif
        // execute dummy command
        let generatedSourcePath = generatedSourceDir
            .appending(component: "ScipioVersion.generated.swift")

        let revision = try? fetchRepositoryVersion(context: context)

        let fileContents: String
        if let revision {
            fileContents = #"let currentScipioVersion: String? = "\#(revision)""#
        } else {
            fileContents = #"let currentScipioVersion: String? = nil"#
        }

        FileManager.default.createFile(
            atPath: generatedSourcePath.path(),
            contents: fileContents.data(using: .utf8)
        )

        return [
            .prebuildCommand(
                displayName: "Generate Scipio Version",
                executable: zshPath,
                arguments: [],
                outputFilesDirectory: generatedSourceDir
            ),
        ]
    }

    private func fetchRepositoryVersion(context: PluginContext) throws -> String? {
        let standardOutput = Pipe()
        let process = Process()
        
        #if compiler(>=6.0)
        let repositoryPath = context.package.directoryURL.path()
        #else
        let repositoryPath = context.package.directory.string
        #endif
        
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-C",
            repositoryPath,
            "rev-parse",
            "HEAD",
        ]
        process.standardOutput = standardOutput

        try process.run()
        process.waitUntilExit()
        let outputData = try standardOutput.fileHandleForReading.readToEnd()
        guard let outputData else { return nil }
        let revision = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return revision
    }
}

#if compiler(<6.0)

// Backward compatibility below 6.0 compiler
// Convert Foundation.URL to Path
extension Command {
    fileprivate static func prebuildCommand(
        displayName: String?,
        executable: URL,
        arguments: [any CustomStringConvertible],
        environment: [String : any CustomStringConvertible] = [:],
        outputFilesDirectory: URL
    ) -> PackagePlugin.Command {
        .prebuildCommand(
            displayName: displayName,
            executable: Path(executable.path()),
            arguments: arguments,
            outputFilesDirectory: Path(outputFilesDirectory.path())
        ),
    }
}

#endif
