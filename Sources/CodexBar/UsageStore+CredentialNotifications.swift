import CodexBarCore
import Foundation

struct CredentialNotificationKey: Hashable {
    let provider: UsageProvider
    let account: String
}

extension UsageStore {
    func claudeCredentialNotificationScope(identity: String?, fingerprint: String?) -> String {
        let account = identity.map { "claude-account:\($0)" }
        let credential = fingerprint.map { "claude-credential:\($0)" }
        let prior = credential.flatMap { self.claudeCredentialNotificationScopes[$0] }
        let scope: String
        if let account {
            if let established = self.claudeCredentialNotificationScopes[account] {
                scope = established
            } else if let prior, !self.claudeCredentialNotificationScopes.contains(where: {
                $0.key.hasPrefix("claude-account:") && $0.value == prior
            }) {
                scope = prior
            } else {
                scope = account
            }
            self.claudeCredentialNotificationScopes[account] = scope
        } else {
            scope = prior ?? credential ?? "default"
        }
        if let credential { self.claudeCredentialNotificationScopes[credential] = scope }
        return scope
    }

    func handleCodexCredentialOutcome(
        _ outcome: ProviderFetchOutcome,
        account: CodexVisibleAccount,
        snapshot: UsageSnapshot?,
        projection: CodexVisibleAccountProjection)
    {
        guard self.shouldApplySelectedCodexVisibleAccountOutcome(outcome, snapshot: snapshot),
              Self.currentCodexVisibleAccount(
                  matching: account,
                  projection: projection,
                  allowProviderAccountAuthFingerprintMismatch: snapshot != nil) != nil else { return }
        let owner = Self.codexSessionQuotaOwnerKey(for: Self.codexScopedRefreshGuard(for: account))
        // Provider-specific by design: this helper validates Codex visible-account ownership before publication.
        self.handleCredentialOutcome(provider: .codex, account: owner?.rawValue ?? account.id, result: outcome.result)
    }

    /// Only accepted, fresh fetch outcomes can end an episode; cached/fallback usage cannot prove recovery.
    func handleCredentialOutcome(
        provider: UsageProvider,
        account: String = "default",
        result: Result<ProviderFetchResult, Error>,
        isCurrent: @escaping @MainActor () -> Bool = { true })
    {
        guard !self.credentialNotificationsStopped else { return }
        let key = CredentialNotificationKey(provider: provider, account: account)
        switch result {
        case let .success(value):
            guard value.diagnostic == nil, value.strategyKind != .localProbe,
                  !value.sourceLabel.lowercased().contains("cache") else { return }
            self.removeCredentialNotification(for: key)
        case let .failure(error):
            guard self.settings.credentialExpiryNotificationsEnabled,
                  ProviderCredentialFailure.isAuthenticationFailure(error),
                  self.credentialNotificationEpisodes[key] == nil else { return }
            let episode = UUID()
            self.credentialNotificationEpisodes[key] = episode
            let revision = self.providerPublicationRevision(for: provider)
            let completion: @MainActor (Bool) -> Void = { [weak self] delivered in
                guard let self, !delivered, self.credentialNotificationEpisodes[key] == episode else { return }
                self.credentialNotificationEpisodes.removeValue(forKey: key)
            }
            let identifier = Self.credentialNotificationIdentifier(episode)
            #if DEBUG
            if let post = self._test_credentialNotificationPost {
                post(identifier, completion)
                return
            }
            #endif
            AppNotifications.shared.post(
                idPrefix: "credential-expired-\(provider.rawValue)",
                title: "\(ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName) needs sign-in",
                body: "Open CodexBar to review the account error and sign in again.",
                identifier: identifier,
                isCurrent: { [weak self] in
                    guard let self else { return false }
                    return self.settings.credentialExpiryNotificationsEnabled && self.isEnabled(provider) &&
                        self.providerPublicationRevision(for: provider) == revision &&
                        self.credentialNotificationEpisodes[key] == episode && isCurrent()
                },
                onCompletion: completion)
        }
    }

    func retireDisabledCredentialNotifications() {
        for provider in Set(self.credentialNotificationEpisodes.keys.map(\.provider))
            where !self.settings.isProviderEnabledCached(provider: provider, metadataByProvider: self.providerMetadata)
        {
            self.retireCredentialNotifications(provider: provider)
        }
    }

    func retireCredentialNotifications(provider: UsageProvider? = nil) {
        for key in self.credentialNotificationEpisodes.keys where provider == nil || key.provider == provider {
            self.removeCredentialNotification(for: key)
        }
    }

    private func removeCredentialNotification(for key: CredentialNotificationKey) {
        guard let episode = self.credentialNotificationEpisodes.removeValue(forKey: key) else { return }
        let identifier = Self.credentialNotificationIdentifier(episode)
        #if DEBUG
        if let remove = self._test_credentialNotificationRemove {
            remove(identifier)
            return
        }
        #endif
        AppNotifications.shared.remove(identifier: identifier)
    }

    private static func credentialNotificationIdentifier(_ episode: UUID) -> String {
        "codexbar-credential-\(episode.uuidString)"
    }
}
