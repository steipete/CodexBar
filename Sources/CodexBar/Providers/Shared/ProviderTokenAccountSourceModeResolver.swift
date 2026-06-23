import CodexBarCore
import Foundation

enum ProviderTokenAccountSourceModeResolver {
    static func effectiveSourceMode(
        base: ProviderSourceMode,
        provider: UsageProvider,
        account: ProviderTokenAccount?) -> ProviderSourceMode
    {
        guard provider == .claude, let account else { return base }

        let routing = self.claudeCredentialRouting(account: account)
        if base == .auto {
            if routing.adminAPIKey != nil { return .api }
            return routing.isOAuth ? .oauth : base
        }

        guard base == .cli else { return base }

        // Claude CLI usage is ambient to the active local CLI profile, so per-account
        // CLI reads can duplicate whichever account is currently active in Claude Code.
        switch routing {
        case .adminAPIKey:
            return .api
        case .oauth:
            return .oauth
        case .webCookie:
            return .web
        case .none:
            return base
        }
    }

    private static func claudeCredentialRouting(account: ProviderTokenAccount) -> ClaudeCredentialRouting {
        if ClaudeCredentialSource.parse(account.token).isRefreshableSource {
            return .oauth(accessToken: "")
        }
        return ClaudeCredentialRouting.resolve(
            tokenAccountToken: account.token,
            manualCookieHeader: nil)
    }
}
