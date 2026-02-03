import CodexBarCore
import Foundation

@MainActor
final class CodeBuddyProviderRuntime: ProviderRuntime {
    let id: UsageProvider = .codebuddy
    private var keepalive: CodeBuddySessionKeepalive?
    private static let log = CodexBarLog.logger(LogCategories.codeBuddyKeepalive)

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
        guard provider == .codebuddy else { return }
        let message = error.localizedDescription
        // Check for session/cookie related errors
        guard message.contains("session expired") ||
              message.contains("401") ||
              message.contains("invalid") && message.contains("cookie")
        else { return }
        Self.log.warning("CodeBuddy session may have expired; triggering recovery")
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
        let shouldRun = context.store.isEnabled(.codebuddy)
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
        Self.log.info(
            "CodeBuddy keepalive check",
            metadata: [
                "enabled": context.store.isEnabled(.codebuddy) ? "1" : "0",
                "available": context.store.isProviderAvailable(.codebuddy) ? "1" : "0",
            ])

        guard context.store.isEnabled(.codebuddy) else {
            Self.log.warning("CodeBuddy keepalive not started (provider disabled)")
            return
        }

        let logger: (String) -> Void = { message in
            Self.log.verbose(message)
        }

        let onSessionRecovered: () async -> Void = { [weak store = context.store] in
            guard let store else { return }
            Self.log.info("CodeBuddy session recovered; refreshing usage")
            await store.refreshProvider(.codebuddy)
        }

        self.keepalive = CodeBuddySessionKeepalive(logger: logger, onSessionRecovered: onSessionRecovered)
        self.keepalive?.start()
        Self.log.info("CodeBuddy keepalive started")
        #endif
    }

    private func stopKeepalive(context _: ProviderRuntimeContext, reason: String) {
        #if os(macOS)
        guard self.keepalive != nil else { return }
        self.keepalive?.stop()
        self.keepalive = nil
        Self.log.info("CodeBuddy keepalive stopped (\(reason))")
        #endif
    }

    private func forceRefresh(context _: ProviderRuntimeContext) async {
        #if os(macOS)
        await self.keepalive?.forceRefresh()
        #endif
    }
}
