import CodexBarCore
import Foundation

extension UsageStore {
    nonisolated static let claudeActiveAccountIdentityDefaultsKey = "ClaudeActiveAccountIdentityHashV2"
    private nonisolated static let claudeActiveAccountIdentityProfileKeySeparator = ".profile."

    struct ClaudeActiveAccountIdentityReconciliation {
        static let unchanged = Self(
            changedFromPersistedIdentity: false,
            changedDuringFetch: false,
            newestIdentity: nil)

        let changedFromPersistedIdentity: Bool
        let changedDuringFetch: Bool
        let newestIdentity: String?

        var changed: Bool {
            self.changedFromPersistedIdentity || self.changedDuringFetch
        }
    }

    /// The currently-active Claude account UUID, read prompt-free from Claude's owner-selected account config.
    /// Claude Code prefers `<config root>/.config.json`, then its `.claude.json` fallback, and rewrites
    /// `oauthAccount.accountUuid` when the active account changes. Returns nil on absence/corruption.
    nonisolated static func activeClaudeAccountUuid(environment: [String: String]) -> String? {
        ClaudeActiveAccountProbe.activeClaudeAccountUuid(environment: environment)
    }

    nonisolated static func activeClaudeAccountIdentity(environment: [String: String]) -> String? {
        self.activeClaudeAccountUuid(environment: environment).map {
            self.claudeAccountIdentity($0, environment: environment)
        }
    }

    nonisolated static func quarantineClaudeCredentialsFileForOAuth(
        environment: [String: String]) async
    {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = ClaudeOAuthCredentialsStore.quarantineCurrentCredentialsFileForOAuth(
                    environment: environment)
            }
            await group.waitForAll()
        }
    }

    nonisolated static func isClaudeCredentialsFileQuarantinedForOAuth(
        environment: [String: String]) async -> Bool
    {
        await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask {
                ClaudeOAuthCredentialsStore.isCurrentCredentialsFileQuarantinedForOAuth(
                    environment: environment)
            }
            return await group.next() ?? false
        }
    }

    /// Compares only hashed identities derived from Claude's plain-text account metadata. A missing identity is
    /// treated as an unavailable observation, not as an account, so transient file absence cannot retire good data.
    /// The caller commits the newest nonnil observation only after the fetch result is admitted.
    func reconcileClaudeActiveAccountIdentity(
        beforeFetch: String?,
        afterFetch: String?,
        observedAccountUuids: [String],
        shouldTrack: Bool,
        environment: [String: String]) -> ClaudeActiveAccountIdentityReconciliation
    {
        guard shouldTrack else { return .unchanged }
        let observedIdentities = [beforeFetch, afterFetch].compactMap(\.self)
        guard !observedIdentities.isEmpty else { return .unchanged }
        let defaults = self.settings.userDefaults
        let persistedIdentity = Self.persistedClaudeActiveAccountIdentity(
            defaults: defaults,
            environment: environment,
            observedAccountUuids: observedAccountUuids)

        let changedFromPersistedIdentity = persistedIdentity.map { persisted in
            observedIdentities.contains { $0 != persisted }
        } ?? false
        let changedDuringFetch = beforeFetch != nil && afterFetch != nil && beforeFetch != afterFetch

        return ClaudeActiveAccountIdentityReconciliation(
            changedFromPersistedIdentity: changedFromPersistedIdentity,
            changedDuringFetch: changedDuringFetch,
            newestIdentity: afterFetch ?? beforeFetch)
    }

    func persistClaudeActiveAccountIdentity(
        _ identity: String?,
        environment: [String: String])
    {
        guard let identity else { return }
        let defaults = self.settings.userDefaults
        let profileIdentifier = ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(environment: environment)
        defaults.set(
            identity,
            forKey: Self.claudeActiveAccountIdentityDefaultsKey(profileIdentifier: profileIdentifier))

        let defaultProfileIdentifier = ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(
            environment: ProcessInfo.processInfo.environment)
        if profileIdentifier == defaultProfileIdentifier {
            defaults.removeObject(forKey: Self.claudeActiveAccountIdentityDefaultsKey)
        }
    }

    nonisolated static func persistedClaudeActiveAccountIdentity(
        defaults: UserDefaults,
        environment: [String: String],
        observedAccountUuids: [String]) -> String?
    {
        let profileIdentifier = ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(environment: environment)
        let scopedKey = self.claudeActiveAccountIdentityDefaultsKey(profileIdentifier: profileIdentifier)
        if let identity = defaults.string(forKey: scopedKey) {
            return self.migrateLegacyClaudeAccountIdentity(
                identity,
                observedAccountUuids: observedAccountUuids,
                scopedKey: scopedKey,
                defaults: defaults,
                environment: environment)
        }

        let defaultProfileIdentifier = ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(
            environment: ProcessInfo.processInfo.environment)
        guard profileIdentifier == defaultProfileIdentifier,
              let legacyIdentity = defaults.string(forKey: self.claudeActiveAccountIdentityDefaultsKey)
        else {
            return nil
        }
        let migratedIdentity = self.migrateLegacyClaudeAccountIdentity(
            legacyIdentity,
            observedAccountUuids: observedAccountUuids,
            scopedKey: scopedKey,
            defaults: defaults,
            environment: environment)
        defaults.set(migratedIdentity, forKey: scopedKey)
        defaults.removeObject(forKey: self.claudeActiveAccountIdentityDefaultsKey)
        return migratedIdentity
    }

    private nonisolated static func claudeActiveAccountIdentityDefaultsKey(
        profileIdentifier: String) -> String
    {
        self.claudeActiveAccountIdentityDefaultsKey +
            self.claudeActiveAccountIdentityProfileKeySeparator +
            profileIdentifier
    }

    nonisolated static func claudeAccountIdentity(
        _ uuid: String,
        environment: [String: String]) -> String
    {
        let profileIdentifier = ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(environment: environment)
        return self.sha256Hex(
            "claude:active-account:v3:\(profileIdentifier):" +
                uuid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private nonisolated static func migrateLegacyClaudeAccountIdentity(
        _ identity: String,
        observedAccountUuids: [String],
        scopedKey: String,
        defaults: UserDefaults,
        environment: [String: String]) -> String
    {
        for uuid in Set(observedAccountUuids) {
            guard self.legacyClaudeAccountIdentities(uuid, environment: environment).contains(identity) else {
                continue
            }
            let migratedIdentity = self.claudeAccountIdentity(uuid, environment: environment)
            defaults.set(migratedIdentity, forKey: scopedKey)
            return migratedIdentity
        }
        return identity
    }

    private nonisolated static func legacyClaudeAccountIdentities(
        _ uuid: String,
        environment: [String: String]) -> Set<String>
    {
        let root = ClaudeConfigPaths.configRoot(environment: environment)
        let fallbackURL = if environment[ClaudeConfigPaths.configDirectoryEnvironmentKey]?.isEmpty == false {
            root.appendingPathComponent(".claude.json")
        } else {
            ClaudeConfigPaths.homeDirectory(environment: environment).appendingPathComponent(".claude.json")
        }
        return Set([
            root.appendingPathComponent(".config.json"),
            fallbackURL,
        ].map { url in
            self.legacyClaudeAccountIdentity(uuid, accountConfigURL: url)
        })
    }

    private nonisolated static func legacyClaudeAccountIdentity(
        _ uuid: String,
        accountConfigURL: URL) -> String
    {
        self.sha256Hex(
            "claude:active-account:v2:\(accountConfigURL.path):" +
                uuid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    #if DEBUG
    nonisolated static func _claudeActiveAccountIdentityDefaultsKeyForTesting(
        environment: [String: String] = [:]) -> String
    {
        self.claudeActiveAccountIdentityDefaultsKey(
            profileIdentifier: ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(environment: environment))
    }

    static func withActiveClaudeAccountUuidForTesting<T>(
        _ uuid: String?,
        _ body: () async throws -> T) async rethrows -> T
    {
        try await ClaudeActiveAccountProbe.$activeClaudeAccountUuidOverrideForTesting.withValue(.value(uuid)) {
            try await body()
        }
    }

    static func withActiveClaudeAccountUuidResolverForTesting<T>(
        _ resolver: @escaping @Sendable () -> String?,
        _ body: () async throws -> T) async rethrows -> T
    {
        try await ClaudeActiveAccountProbe.$activeClaudeAccountUuidOverrideForTesting.withValue(.resolver(resolver)) {
            try await body()
        }
    }

    nonisolated static func _activeClaudeAccountIdentityForTesting(
        _ uuid: String,
        environment: [String: String] = [:]) -> String
    {
        self.claudeAccountIdentity(uuid, environment: environment)
    }

    nonisolated static func _legacyClaudeActiveAccountIdentityForTesting(
        _ uuid: String,
        accountConfigURL: URL) -> String
    {
        self.legacyClaudeAccountIdentity(uuid, accountConfigURL: accountConfigURL)
    }

    nonisolated static func _activeClaudeAccountIdentityFromEnvironmentForTesting(
        _ environment: [String: String]) -> String?
    {
        self.activeClaudeAccountIdentity(environment: environment)
    }
    #endif
}

/// Prompt-free reader for the active Claude account UUID recorded in Claude's owner-selected account config. The
/// `@TaskLocal` test seam lives here (not on `UsageStore`) because Swift forbids stored properties in extensions and
/// task-local storage must be nonisolated, whereas `UsageStore` is `@MainActor`.
private enum ClaudeActiveAccountProbe {
    #if DEBUG
    enum Override: Sendable {
        case value(String?)
        case resolver(@Sendable () -> String?)
    }

    @TaskLocal static var activeClaudeAccountUuidOverrideForTesting: Override?
    #endif

    static func activeClaudeAccountUuid(environment: [String: String]) -> String? {
        #if DEBUG
        if case let .value(uuid) = self.activeClaudeAccountUuidOverrideForTesting {
            return uuid
        }
        if case let .resolver(resolver) = self.activeClaudeAccountUuidOverrideForTesting {
            return resolver()
        }
        #endif
        return ClaudeAccountProfile.accountUuid(environment: environment)
    }
}
