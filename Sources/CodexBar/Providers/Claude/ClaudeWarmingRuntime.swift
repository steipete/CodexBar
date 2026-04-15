import CodexBarCore
import Foundation

@MainActor
final class ClaudeWarmingRuntime: ProviderRuntime {
    let id: UsageProvider = .claude
    private(set) var warmingService: ClaudeWarmingService?

    func start(context: ProviderRuntimeContext) {
        if warmingService == nil {
            warmingService = ClaudeWarmingService()
        }
        updateWarmingState(context: context)
    }

    func stop(context _: ProviderRuntimeContext) {
        warmingService?.stop()
    }

    func settingsDidChange(context: ProviderRuntimeContext) {
        updateWarmingState(context: context)
    }

    private func updateWarmingState(context: ProviderRuntimeContext) {
        let shouldRun = context.settings.claudeWarmingEnabled
            && context.store.isEnabled(.claude)
        if shouldRun {
            if warmingService == nil {
                warmingService = ClaudeWarmingService()
            }
            if let service = warmingService, !service.isRunning {
                service.start()
            }
        } else {
            warmingService?.stop()
        }
    }
}
