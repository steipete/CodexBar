import CodexBarCore
import Foundation

@MainActor
final class AugmentProviderRuntime: ProviderRuntime {
    let id: UsageProvider = .augment
    private var keepalive: AugmentSessionKeepalive?

    func start(context: ProviderRuntimeContext) {
        self.updateKeepalive(context: context)
    }

    func stop(context: ProviderRuntimeContext) {
        self.stopKeepalive(context: context, reason: "provider disabled")
    }

    func settingsDidChange(context: ProviderRuntimeContext) {
        self.updateKeepalive(context: context)
    }

    func providerDidFail(context: ProviderRuntimeContext, provider: UsageProvider, error: Error) {
        guard provider == .augment else { return }
        let message = error.localizedDescription
        guard message.contains("session expired") else { return }
        context.store.augmentLogger.warning("Augment session expired; triggering recovery")
        Task { [weak self] in
            guard let self else { return }
            await self.forceRefresh(context: context)
        }
    }

    func perform(action: ProviderRuntimeAction, context: ProviderRuntimeContext) async {
        switch action {
        case .forceSessionRefresh:
            await self.forceRefresh(context: context)
        case .openAIWebAccessToggled:
            break
        }
    }

    private func updateKeepalive(context: ProviderRuntimeContext) {
        #if os(macOS)
        let shouldRun = context.store.isEnabled(.augment)
        let isRunning = self.keepalive != nil

        if shouldRun, !isRunning {
            self.startKeepalive(context: context)
        } else if !shouldRun, isRunning {
            self.stopKeepalive(context: context, reason: "provider disabled")
        }
        #endif
    }

    private func startKeepalive(context: ProviderRuntimeContext) {
        #if os(macOS)
        context.store.augmentLogger.info(
            "Augment keepalive check",
            metadata: [
                "enabled": context.store.isEnabled(.augment) ? "1" : "0",
                "available": context.store.isProviderAvailable(.augment) ? "1" : "0",
            ])

        guard context.store.isEnabled(.augment) else {
            context.store.augmentLogger.warning("Augment keepalive not started (provider disabled)")
            return
        }

        let logger: (String) -> Void = { [augmentLogger = context.store.augmentLogger] message in
            augmentLogger.verbose(message)
        }

        let onSessionRecovered: () async -> Void = { [weak store = context.store] in
            guard let store else { return }
            store.augmentLogger.info("Augment session recovered; refreshing usage")
            await store.refreshProvider(.augment)
        }

        self.keepalive = AugmentSessionKeepalive(logger: logger, onSessionRecovered: onSessionRecovered)
        self.keepalive?.start()
        context.store.augmentLogger.info("Augment keepalive started")
        #endif
    }

    private func stopKeepalive(context: ProviderRuntimeContext, reason: String) {
        #if os(macOS)
        self.keepalive?.stop()
        self.keepalive = nil
        context.store.augmentLogger.info("Augment keepalive stopped (\(reason))")
        #endif
    }

    private func forceRefresh(context: ProviderRuntimeContext) async {
        #if os(macOS)
        context.store.augmentLogger.info("Augment force refresh requested")
        guard let keepalive = self.keepalive else {
            context.store.augmentLogger.warning("Augment keepalive not running; starting")
            self.startKeepalive(context: context)
            try? await Task.sleep(for: .seconds(1))
            guard let keepalive = self.keepalive else {
                context.store.augmentLogger.error("Augment keepalive failed to start")
                return
            }
            await keepalive.forceRefresh()
            return
        }

        await keepalive.forceRefresh()
        context.store.augmentLogger.info("Refreshing Augment usage after session refresh")
        await context.store.refreshProvider(.augment)
        #endif
    }
}
