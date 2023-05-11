import Foundation
import PackagePlugin

@main
struct GenerateScipioVersion: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let zshPath = Path("/bin/zsh") // execute dummy command
        let generatedSourceDir = context.pluginWorkDirectory
        let generatedSourcePath = generatedSourceDir
            .appending(subpath: "ScipioVersion.generated.swift")

        let versionName: String?
        if let scipioPackage = context.package.dependencies.first(where: { $0.package.displayName.lowercased() == "scipio" })?.package {
            versionName = fetchVersionName(of: scipioPackage.origin)
        } else {
            versionName = nil
        }

        let fileContents: String
        if let versionName {
            fileContents = #"let currentScipioVersion: String? = "\#(versionName)""#
        } else {
            fileContents = #"let currentScipioVersion: String? = nil"#
        }

        print(context.package.origin)
        print("Current scipio version is \(versionName ?? "unknown")")

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

    private func fetchVersionName(of packageOrigin: PackageOrigin) -> String? {
        switch packageOrigin {
        case .root:
            return "root"
        case .local(_):
            return "local"
        case .repository(_, _, let scmRevision):
            return scmRevision
        case .registry(_, let displayVersion):
            return displayVersion
        @unknown default:
            return nil
        }
    }
}
