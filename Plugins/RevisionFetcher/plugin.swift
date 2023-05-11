import Foundation
import PackagePlugin

@main
struct PrepareMilepost: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let zshPath = try context.tool(named: "zsh") // execute dummy command
        let generatedSourceDir = context.pluginWorkDirectory
        let generatedSourcePath = generatedSourceDir
            .appending(subpath: "ScipioVersion.generated.swift")
        let versionName = versionName(of: context.package.origin)

        let fileContents: String
        if let versionName {
            fileContents = #"let currentScipioVersion: String? = "\#(versionName)""#
        } else {
            fileContents = #"let currentScipioVersion: String? = nil"#
        }

        FileManager.default.createFile(
            atPath: generatedSourcePath.string,
            contents: fileContents.data(using: .utf8)
        )

        return [
            .prebuildCommand(
                displayName: "Generate Scipio Version",
                executable: zshPath.path,
                arguments: [],
                outputFilesDirectory: generatedSourceDir
            ),
        ]
    }

    private func versionName(of packageOrigin: PackageOrigin) -> String? {
        switch packageOrigin {
        case .root:
            return nil
        case .local(_):
            return nil
        case .repository(_, _, let scmRevision):
            return scmRevision
        case .registry(_, let displayVersion):
            return displayVersion
        @unknown default:
            return nil
        }
    }
}
