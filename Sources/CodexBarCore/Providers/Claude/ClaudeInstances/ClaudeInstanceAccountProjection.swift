import Foundation

/// Projects per-instance Claude CLI results into the provider-neutral account snapshot consumed by menus.
/// Identity is the instance's stored ID (`claude-instance:<id>`), never an email or a path.
public enum ClaudeInstanceAccountProjection {
    public static let sourceName = "claude-instance"
    public static let sourceLabel = "claude-instance"

    public static func identity(for instance: ClaudeInstanceConfig) -> ProviderAccountIdentity {
        ProviderAccountIdentity(source: self.sourceName, opaqueID: instance.id)
    }

    public static func displayLabel(for instance: ClaudeInstanceConfig, index: Int) -> String {
        let name = instance.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Instance \(index + 1)" : name
    }

    /// A failed refresh keeps the instance's last successful usage and reports the error beside it.
    public static func accountSnapshot(
        for instance: ClaudeInstanceConfig,
        index: Int,
        result: Result<UsageSnapshot, Error>,
        previous: ProviderAccountUsageSnapshot?) -> ProviderAccountUsageSnapshot
    {
        let snapshot: UsageSnapshot?
        let error: String?
        switch result {
        case let .success(usage):
            snapshot = usage
            error = nil
        case let .failure(failure):
            let message = (failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription
            snapshot = previous?.snapshot
            error = snapshot == nil
                ? message
                : ClaudeSwapAccountProjection.displayError(accountError: nil, adapterError: message)
        }
        return ProviderAccountUsageSnapshot(
            id: self.identity(for: instance),
            provider: .claude,
            displayLabel: self.displayLabel(for: instance, index: index),
            accountEmail: snapshot?.identity?.accountEmail,
            isActive: false,
            canActivate: false,
            snapshot: snapshot,
            error: error,
            sourceLabel: self.sourceLabel)
    }
}
