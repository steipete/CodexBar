import CodexBarCore
import Foundation

extension UsageStore {
    /// Codex `…/sessions` directory for the credentials dir selected in Settings (path-based token accounts), or `nil`
    /// to use the process environment / `~/.codex`.
    /// Whether cost data should be suppressed because "CodexBar accounts only" is on
    /// and no explicit account is selected (would otherwise fall back to ~/.codex).
    var shouldSuppressDefaultCostData: Bool {
        guard self.settings.codexExplicitAccountsOnly else { return false }
        let defaultActive = self.settings.isDefaultTokenAccountActive(for: .codex)
        if defaultActive { return true }
        return self.settings.selectedTokenAccount(for: .codex) == nil
    }

    /// True when the active Codex credentials resolve to API-key auth.
    /// API-authenticated accounts have no local session logs; cost is fetched via the OpenAI REST API instead.
    var isActiveCodexAccountApiKey: Bool {
        self.activeCodexApiKey != nil
    }

    /// The raw API key for the active Codex credentials, whether it comes from a selected API-key row or the
    /// resolved `auth.json`.
    var activeCodexApiKey: String? {
        self.settings.activeCodexAPIKey()
    }

    var activeCodexAPIKeyAccount: ProviderTokenAccount? {
        guard let account = self.settings.selectedTokenAccount(for: .codex) else { return nil }
        let token = account.token.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.lowercased().hasPrefix("apikey:") ? account : nil
    }

    func activeCodexAPIKeySettingsNotice() -> String? {
        guard let account = self.activeCodexAPIKeyAccount else { return nil }
        let error = self.tokenError(for: .codex)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !error.isEmpty else { return nil }
        return "\(account.displayName): \(error)"
    }

    func activeCodexAPIKeyCreditsMessage() -> String? {
        if let account = self.activeCodexAPIKeyAccount {
            return "\(account.displayName) is an API key account. " +
                "ChatGPT credits are not available here; use Subscription Utilization for API spend."
        }
        guard self.activeCodexApiKey != nil else { return nil }
        return "This Codex account uses API key auth. " +
            "ChatGPT credits are not available here; use Subscription Utilization for API spend."
    }

    func codexCostUsageSessionsRootForActiveSelection() -> URL? {
        guard let support = TokenAccountSupportCatalog.support(for: .codex),
              case .codexHome = support.injection
        else { return nil }
        let defaultActive = self.settings.isDefaultTokenAccountActive(for: .codex)
        if defaultActive { return nil }
        guard let account = self.settings.selectedTokenAccount(for: .codex) else { return nil }
        let token = account.token.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiPrefix = "apikey:"
        if token.lowercased().hasPrefix(apiPrefix) { return nil }
        let expanded = (token as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return nil }
        return URL(fileURLWithPath: expanded).appendingPathComponent("sessions", isDirectory: true)
    }

    /// Stable key for the local logs backing token-cost; when it changes, cached cost data must refresh.
    func tokenCostSelectionIdentity(for provider: UsageProvider) -> String {
        if provider == .codex {
            if let root = self.codexCostUsageSessionsRootForActiveSelection() {
                return root.path
            }
            if self.activeCodexApiKey != nil {
                if let account = self.settings.selectedTokenAccount(for: .codex) {
                    return "codex:apikey:\(account.id.uuidString)"
                }
                return "codex:default:apikey"
            }
            // When no API auth is active, keep a stable identity for the default auth path.
            if let account = self.settings.selectedTokenAccount(for: .codex) {
                let token = account.token.trimmingCharacters(in: .whitespacesAndNewlines)
                if token.lowercased().hasPrefix("apikey:") {
                    return "codex:apikey:\(account.id.uuidString)"
                }
            }
            return "codex:default"
        }
        return "\(provider.rawValue):default"
    }

    func tokenSnapshot(for provider: UsageProvider) -> CostUsageTokenSnapshot? {
        self.tokenSnapshots[provider]
    }

    func tokenError(for provider: UsageProvider) -> String? {
        self.tokenErrors[provider]
    }

    func tokenLastAttemptAt(for provider: UsageProvider) -> Date? {
        self.lastTokenFetchAt[provider]
    }

    func isTokenRefreshInFlight(for provider: UsageProvider) -> Bool {
        self.tokenRefreshInFlight.contains(provider)
    }

    func resolvedTokenCostNoDataMessage(for provider: UsageProvider) -> String {
        if provider == .codex, let sessionsRoot = self.codexCostUsageSessionsRootForActiveSelection() {
            return Self.codexTokenCostNoDataMessage(sessionsRoot: sessionsRoot)
        }
        return Self.tokenCostNoDataMessage(for: provider)
    }

    nonisolated static func costUsageCacheDirectory(
        fileManager: FileManager = .default) -> URL
    {
        let root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("cost-usage", isDirectory: true)
    }

    nonisolated static func tokenCostNoDataMessage(for provider: UsageProvider) -> String {
        ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.noDataMessage()
    }

    nonisolated static func codexTokenCostNoDataMessage(sessionsRoot: URL) -> String {
        let sessionsPath = sessionsRoot.standardizedFileURL.path
        let archivedPath = sessionsRoot
            .deletingLastPathComponent()
            .appendingPathComponent("archived_sessions", isDirectory: true)
            .standardizedFileURL
            .path
        return "No Codex sessions found in \(sessionsPath) or \(archivedPath). " +
            "Run `codex` once while this account is active to start tracking cost."
    }
}
