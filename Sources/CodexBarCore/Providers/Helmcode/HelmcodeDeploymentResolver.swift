import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Shared tenant detection for the Helmcode provider: used by the web fetch strategy, the app
/// settings picker, and the menu's dashboard action so automatic mode behaves identically everywhere.
public enum HelmcodeDeploymentResolver {
    /// Detects the tenant from a pasted cURL capture by its URL host. A bare `Cookie:` header has no
    /// host and returns nil, so the caller can fall back to Helmcode Cloud without sending the paste
    /// to both tenants.
    public static func detectTenant(fromCookieCapture raw: String?) -> HelmcodeDeployment? {
        guard let raw, !raw.isEmpty else { return nil }
        let hosts = Self.urls(in: raw).compactMap { $0.host?.lowercased() }
        for host in hosts {
            if host == "nan.builders" || host.hasSuffix(".nan.builders") {
                return .nanBuilders
            }
            if host.hasSuffix("helmcode.com") {
                return .helmcode
            }
        }
        return nil
    }

    /// Tenant decided by the persisted session cache: an entry in exactly one deployment's scope
    /// decides; entries in both scopes pick the newer `storedAt`; no entries → nil.
    public static func detectTenantFromCache() -> HelmcodeDeployment? {
        let entries = HelmcodeDeployment.allCases.compactMap { deployment -> (
            deployment: HelmcodeDeployment,
            storedAt: Date)? in
            guard let entry = CookieHeaderCache.load(
                provider: .helmcode,
                scope: HelmcodeWebFetchStrategy.cacheScope(deployment)),
                !entry.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return (deployment, entry.storedAt)
        }
        if entries.count == 1 { return entries[0].deployment }
        guard entries.count == 2 else { return nil }
        return entries.max { $0.storedAt < $1.storedAt }?.deployment
    }

    /// Explicit tenant choice: an explicit `HELMCODE_DEPLOYMENT` value wins, then the stored
    /// selection, defaulting to automatic detection.
    public static func resolveSelection(
        settings: HelmcodeProviderSettings?,
        environment: [String: String]) -> HelmcodeDeploymentSelection
    {
        let hasEnvironmentOverride = environment[HelmcodeDeploymentSelection.environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if hasEnvironmentOverride {
            return HelmcodeDeploymentSelection.resolve(environment: environment)
        }
        return settings?.deploymentSelection ?? .auto
    }

    /// The tenant a pasted cookie must go to. An explicit selection pins the tenant; automatic mode
    /// detects the host from a cURL capture and falls back to Helmcode Cloud for bare headers, so a
    /// paste is never sent to both hosts.
    public static func tenant(
        forManualCookie raw: String?,
        selection: HelmcodeDeploymentSelection) -> HelmcodeDeployment
    {
        if let pinned = selection.pinnedDeployment {
            return pinned
        }
        return Self.detectTenant(fromCookieCapture: raw) ?? .helmcode
    }

    private static func urls(in raw: String) -> [URL] {
        raw.split { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "'" || $0 == "\"" || $0 == "\\" }
            .map(String.init)
            .compactMap { token in
                let lowered = token.lowercased()
                guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") else { return nil }
                return URL(string: token)
            }
    }
}
