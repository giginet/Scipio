import Foundation
import PackagePlugin

@main
struct GenerateScipioVersion: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let standardOutput = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-C",
            context.package.directory.string,
            "rev-parse",
            "HEAD",
        ]
        process.standardOutput = standardOutput

        try process.run()
        process.waitUntilExit()
        let outputData = try standardOutput.fileHandleForReading.readToEnd()
        guard let outputData else { return [] }
        let revision = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let zshPath = Path("/bin/zsh") // execute dummy command
        let generatedSourceDir = context.pluginWorkDirectory
        let generatedSourcePath = generatedSourceDir
            .appending(subpath: "ScipioVersion.generated.swift")

        let fileContents: String
        if let revision {
            fileContents = #"let currentScipioVersion: String? = "\#(revision)""#
        } else {
            fileContents = #"let currentScipioVersion: String? = nil"#
        }

        print("Current scipio version is \(revision ?? "unknown")")

        FileManager.default.createFile(
            atPath: generatedSourcePath.string,
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
}
