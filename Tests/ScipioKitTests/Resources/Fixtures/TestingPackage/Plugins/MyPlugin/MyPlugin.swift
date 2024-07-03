import PackagePlugin

@main
struct MyPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {}
}
