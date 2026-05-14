import Foundation

enum LocalizedProviderText {
    static func sourceLabel(_ raw: String) -> String {
        raw.split(separator: "+", omittingEmptySubsequences: false)
            .map { self.sourceComponent(String($0)) }
            .joined(separator: " + ")
    }

    static func statusText(_ status: ProviderStatus) -> String {
        if status.indicator == .none {
            return status.indicator.label
        }

        guard let description = status.description?.trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty
        else {
            return status.indicator.label
        }
        return L(description)
    }

    private static func sourceComponent(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "api":
            return L("source_api")
        case "auto":
            return L("source_auto")
        case "cached":
            return L("source_cached")
        case "claude":
            return L("source_claude_cli")
        case "cli":
            return L("source_cli")
        case "codex-cli":
            return L("source_codex_cli")
        case "local":
            return L("source_local")
        case "login":
            return L("source_login")
        case "manual":
            return L("source_manual")
        case "manual cookie header":
            return L("source_manual_cookie_header")
        case "oauth":
            return L("source_oauth")
        case "oauth-api":
            return L("source_oauth_api")
        case "off":
            return L("source_off")
        case "openai-web":
            return L("source_openai_web")
        case "web":
            return L("source_web")
        case "windsurf-web":
            return L("source_windsurf_web")
        default:
            return L(trimmed)
        }
    }
}
