import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    nonisolated static func isPermissionPromptWaiting(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return (message.contains("prompt") && message.contains("waiting")) ||
            message.contains("permission prompt") ||
            message.contains("folder trust prompt")
    }

    func postPermissionPromptNotificationIfNeeded(provider: UsageProvider, error: Error) {
        let now = Date()
        if let last = self.lastPermissionPromptNotificationAt[provider.instanceID],
           now.timeIntervalSince(last) < 10 * 60
        {
            return
        }
        self.lastPermissionPromptNotificationAt[provider.instanceID] = now
        let providerName = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
        AppNotifications.shared.post(
            idPrefix: "permission-prompt-\(provider.rawValue)",
            title: L("%@ is waiting for permission", providerName),
            body: error.localizedDescription,
            soundEnabled: false)
    }
}
