import CodexBarCore
import Foundation

extension UsageStore {
    var codexSnapshot: UsageSnapshot? {
        self.snapshots[.codex]
    }

    var claudeSnapshot: UsageSnapshot? {
        self.snapshots[.claude]
    }

    var lastCodexError: String? {
        self.errors[.codex]
    }

    var userFacingLastCodexError: String? {
        self.userFacingError(for: .codex)
    }

    var userFacingLastCreditsError: String? {
        self.userFacingCodexUIError(self.lastCreditsError)
    }

    var userFacingLastOpenAIDashboardError: String? {
        self.userFacingCodexUIError(self.lastOpenAIDashboardError)
    }

    var lastClaudeError: String? {
        self.errors[.claude]
    }

    func error(for provider: UsageProvider) -> String? {
        self.errors[provider]
    }

    func userFacingError(for provider: UsageProvider) -> String? {
        let raw = self.errors[provider]
        guard provider == .codex else { return raw }
        return self.userFacingCodexUIError(raw)
    }

    func status(for provider: UsageProvider) -> ProviderStatus? {
        guard self.statusChecksEnabled else { return nil }
        return self.statuses[provider]
    }

    func statusIndicator(for provider: UsageProvider) -> ProviderStatusIndicator {
        self.status(for: provider)?.indicator ?? .none
    }

    func accountInfo(for provider: UsageProvider) -> AccountInfo {
        guard provider == .codex else {
            return self.codexFetcher.loadAccountInfo()
        }
        let env = ProviderRegistry.makeEnvironment(
            base: ProcessInfo.processInfo.environment,
            provider: .codex,
            settings: self.settings,
            tokenOverride: nil)
        let fetcher = ProviderRegistry.makeFetcher(base: self.codexFetcher, provider: .codex, env: env)
        return fetcher.loadAccountInfo()
    }

    private func userFacingCodexUIError(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        if self.codexErrorIsAlreadyUserFacing(lower: lower) {
            return trimmed
        }

        if let cachedMessage = self.userFacingCachedCodexError(trimmed, lower: lower) {
            return cachedMessage
        }

        if self.codexErrorLooksExpired(lower: lower) {
            return "Codex session expired. Sign in again."
        }

        if lower.contains("frame load interrupted") {
            return "OpenAI web refresh was interrupted. Refresh OpenAI cookies and try again."
        }

        if self.codexErrorLooksInternalTransport(lower: lower) {
            return "Codex usage is temporarily unavailable. Try refreshing."
        }

        return trimmed
    }

    private func userFacingCachedCodexError(_ raw: String, lower: String) -> String? {
        let cachedMarker = " Cached values from "
        guard let suffixRange = raw.range(of: cachedMarker) else { return nil }

        let suffix = String(raw[suffixRange.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.hasPrefix("last codex credits refresh failed:"),
           let base = self.userFacingCodexUIError(String(raw[..<suffixRange.lowerBound]))
        {
            return "\(base) \(suffix)"
        }

        if lower.hasPrefix("last openai dashboard refresh failed:"),
           let base = self.userFacingCodexUIError(String(raw[..<suffixRange.lowerBound]))
        {
            return "\(base) \(suffix)"
        }

        return nil
    }

    private func codexErrorIsAlreadyUserFacing(lower: String) -> Bool {
        lower.contains("openai cookies are for")
            || lower.contains("sign in to chatgpt.com")
            || lower.contains("requires a signed-in chatgpt.com session")
            || lower.contains("managed codex account data is unavailable")
            || lower.contains("selected managed codex account is unavailable")
            || lower.contains("codex credits are still loading")
            || lower.contains("codex account changed; importing browser cookies")
            || lower.contains("codex session expired. sign in again.")
            || lower.contains("codex usage is temporarily unavailable. try refreshing.")
    }

    private func codexErrorLooksExpired(lower: String) -> Bool {
        lower.contains("token_expired")
            || lower.contains("authentication token is expired")
            || lower.contains("oauth token has expired")
            || lower.contains("provided authentication token is expired")
            || lower.contains("please try signing in again")
            || lower.contains("please sign in again")
            || (lower.contains("401") && lower.contains("unauthorized"))
    }

    private func codexErrorLooksInternalTransport(lower: String) -> Bool {
        lower.contains("codex connection failed")
            || lower.contains("failed to fetch codex rate limits")
            || lower.contains("/backend-api/")
            || lower.contains("content-type=")
            || lower.contains("body={")
            || lower.contains("body=")
            || lower.contains("get https://")
            || lower.contains("get http://")
            || lower.contains("returned invalid data")
    }
}
