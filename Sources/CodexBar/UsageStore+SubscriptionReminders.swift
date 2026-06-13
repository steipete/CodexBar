import CodexBarCore

extension UsageStore {
    func handleProviderSubscriptionReminders(provider: UsageProvider) {
        guard provider == .codex else { return }
        let previous = self.settings.providerSubscriptionReminderState(for: provider)
        guard let subscription = self.settings.providerSubscriptionSnapshot(for: provider),
              subscription.hasDisplayableDate
        else {
            if previous != nil {
                self.settings.setProviderSubscriptionReminderState(for: provider, state: nil)
            }
            return
        }

        let providerName = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
        let result = ProviderSubscriptionReminderLogic.evaluate(
            providerName: providerName,
            snapshot: subscription,
            previous: previous)
        if let state = result.state {
            self.settings.setProviderSubscriptionReminderState(for: provider, state: state)
        }
        for event in result.events {
            self.sessionQuotaNotifier.postProviderSubscriptionReminder(provider: provider, event: event, badge: nil)
        }
    }
}
