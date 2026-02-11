import Foundation

public enum CodexUsageDataSource: String, CaseIterable, Identifiable, Sendable {
    case auto
    case oauth
    case api
    case cli

    public var id: String {
        self.rawValue
    }

    public var displayName: String {
        switch self {
        case .auto:
            L10n.tr("provider.codex.source.auto", fallback: "Auto")
        case .oauth:
            L10n.tr("provider.codex.source.oauth", fallback: "OAuth API")
        case .api:
            L10n.tr("provider.codex.source.api", fallback: "CLIProxyAPI")
        case .cli:
            L10n.tr("provider.codex.source.cli", fallback: "CLI (RPC/PTY)")
        }
    }

    public var sourceLabel: String {
        switch self {
        case .auto:
            "auto"
        case .oauth:
            "oauth"
        case .api:
            "cliproxy-api"
        case .cli:
            "cli"
        }
    }
}
