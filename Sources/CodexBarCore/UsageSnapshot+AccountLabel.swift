import Foundation

extension UsageSnapshot {
    package func withAccountLabel(_ label: String, for provider: UsageProvider) -> UsageSnapshot {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return self }
        let existing = self.identity(for: provider.instanceID)
        let email = existing?.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedEmail = (email?.isEmpty ?? true) ? label : email
        return self.withIdentity(ProviderIdentitySnapshot(
            providerID: provider.instanceID,
            accountEmail: resolvedEmail,
            accountOrganization: existing?.accountOrganization,
            loginMethod: existing?.loginMethod,
            accountID: existing?.accountID))
    }
}
