import Foundation

/// The external tool CodexBar runs to list Claude accounts.
///
/// Every source prints claude-swap's list schema v1, so one parser and one
/// projection serve them all; a source only fixes the argument array, the
/// account identity prefix and the label shown on cards.
public enum ClaudeSwapAccountSource: String, CaseIterable, Sendable {
    /// claude-swap (`cswap --list --json`), github.com/realiti4/claude-swap.
    case claudeSwap = "claude-swap"
    /// tcr (`tcr list --json`), the teamclaude-rs pooling proxy. tcr routes
    /// each request to a pooled account, so its list reports no active account
    /// and `supportsAccountSwitching: false`.
    case tcr

    /// Identity prefix (`<source>:<slot>`) and card label.
    public var label: String {
        self.rawValue
    }

    /// The fixed list argument array. Never a shell, never config-defined arguments.
    public var listArguments: [String] {
        switch self {
        case .claudeSwap: ["--list", "--json"]
        case .tcr: ["list", "--json"]
        }
    }

    public init?(identitySource: String) {
        self.init(rawValue: identitySource)
    }
}
