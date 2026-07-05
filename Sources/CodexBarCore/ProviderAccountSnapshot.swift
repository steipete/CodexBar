import Foundation

/// Stable identity for one account row surfaced by a multi-account source adapter.
///
/// `source` names the adapter (for example `claude-swap`) and `opaqueID` is the
/// source-issued identifier (for example a numeric slot). Identity never derives
/// from emails or credential material, per
/// `docs/claude-multi-account-and-status-items.md`.
public struct ProviderAccountIdentity: Hashable, Sendable {
    public let source: String
    public let opaqueID: String

    public init(source: String, opaqueID: String) {
        self.source = source
        self.opaqueID = opaqueID
    }
}

/// Provider-neutral projection of one account's usage, consumed by menus (and,
/// later, per-account status items) without teaching UI code about any specific
/// credential source.
public struct ProviderAccountUsageSnapshot: Identifiable, Sendable {
    public let id: ProviderAccountIdentity
    public let provider: UsageProvider
    /// Display-only label (may contain personal data such as an email); UI is
    /// responsible for privacy redaction. Never logged or persisted.
    public let displayLabel: String
    public let isActive: Bool
    /// Whether the source can make this inactive account the provider's active account.
    /// Activation remains source-owned; CodexBar never handles credential material.
    public let canActivate: Bool
    public let snapshot: UsageSnapshot?
    public let error: String?
    public let sourceLabel: String?

    public init(
        id: ProviderAccountIdentity,
        provider: UsageProvider,
        displayLabel: String,
        isActive: Bool,
        canActivate: Bool = false,
        snapshot: UsageSnapshot?,
        error: String?,
        sourceLabel: String?)
    {
        self.id = id
        self.provider = provider
        self.displayLabel = displayLabel
        self.isActive = isActive
        self.canActivate = canActivate
        self.snapshot = snapshot
        self.error = error
        self.sourceLabel = sourceLabel
    }
}
