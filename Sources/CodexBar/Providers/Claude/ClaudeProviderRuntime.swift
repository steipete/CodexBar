import CodexBarCore

@MainActor
final class ClaudeProviderRuntime: ProviderRuntime {
    let id: UsageProvider = .claude
    private var lastSwapConfiguration: Configuration?
    private var lastInstanceConfiguration: InstanceConfiguration?

    func start(context: ProviderRuntimeContext) {
        self.reconcileSwapConfiguration(context: context)
        self.reconcileInstanceConfiguration(context: context)
    }

    func stop(context: ProviderRuntimeContext) {
        self.lastSwapConfiguration = nil
        self.lastInstanceConfiguration = nil
        context.store.clearClaudeSwapAccountState()
        context.store.clearClaudeInstanceState()
    }

    func settingsDidChange(context: ProviderRuntimeContext) {
        self.reconcileSwapConfiguration(context: context)
        self.reconcileInstanceConfiguration(context: context)
    }

    private func reconcileSwapConfiguration(context: ProviderRuntimeContext) {
        let configuration = Configuration(
            providerEnabled: context.store.isEnabled(.claude),
            enabled: context.settings.claudeSwapEnabled,
            executablePath: context.settings.claudeSwapExecutablePath)
        guard configuration != self.lastSwapConfiguration else { return }
        self.lastSwapConfiguration = configuration

        // Cancel before clearing so an old executable can never repopulate the menu.
        context.store.clearClaudeSwapAccountState()
        guard configuration.providerEnabled, configuration.enabled, !configuration.executablePath.isEmpty else {
            return
        }
        context.store.scheduleClaudeSwapAccountRefresh()
    }

    private func reconcileInstanceConfiguration(context: ProviderRuntimeContext) {
        let configuration = InstanceConfiguration(
            providerEnabled: context.store.isEnabled(.claude),
            enabled: context.settings.claudeInstancesEnabled,
            instances: context.settings.claudeInstances)
        guard configuration != self.lastInstanceConfiguration else { return }
        self.lastInstanceConfiguration = configuration

        // Cancel before clearing so a removed or edited instance can never repopulate the menu.
        context.store.clearClaudeInstanceState()
        guard configuration.providerEnabled, configuration.enabled, !configuration.instances.isEmpty else {
            return
        }
        context.store.scheduleClaudeInstanceRefresh()
    }

    private struct Configuration: Equatable {
        let providerEnabled: Bool
        let enabled: Bool
        let executablePath: String
    }

    private struct InstanceConfiguration: Equatable {
        let providerEnabled: Bool
        let enabled: Bool
        let instances: [ClaudeInstanceConfig]
    }
}
