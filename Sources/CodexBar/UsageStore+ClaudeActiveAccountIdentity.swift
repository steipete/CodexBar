import CodexBarCore
import Foundation

extension UsageStore {
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

    private nonisolated static func claudeAccountIdentity(
        _ uuid: String,
        environment: [String: String]) -> String
    {
        let configPath = ClaudeConfigPaths.accountConfigURL(environment: environment).path
        return self.sha256Hex(
            "claude:active-account:v2:\(configPath):" +
                uuid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    #if DEBUG
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
