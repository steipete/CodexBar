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
            if host == "helmcode.com" || host.hasSuffix(".helmcode.com") {
                return .helmcode
            }
        }
        return nil
    }

    /// Tenant decided by the persisted session cache: an entry in exactly one deployment's scope
    /// decides; entries in both scopes pick the newer `storedAt`; no entries → nil. The fetch path
    /// reads with `load`; display paths (Settings subtitle, dashboard action) use `loadForDisplay` to
    /// avoid a synchronous Keychain round-trip per scope on every SwiftUI body evaluation.
    public static func detectTenantFromCache() -> HelmcodeDeployment? {
        self.detectTenantFromCache(load: { provider, scope in
            CookieHeaderCache.load(provider: provider, scope: scope)
        })
    }

    public static func detectTenantFromCacheForDisplay() -> HelmcodeDeployment? {
        self.detectTenantFromCache(load: { provider, scope in
            CookieHeaderCache.loadForDisplay(provider: provider, scope: scope)
        })
    }

    private static func detectTenantFromCache(
        load: (_ provider: UsageProvider, _ scope: CookieHeaderCache.Scope?) -> CookieHeaderCache.Entry?)
        -> HelmcodeDeployment?
    {
        let entries = HelmcodeDeployment.allCases.compactMap { deployment -> (
            deployment: HelmcodeDeployment,
            storedAt: Date)? in
            guard let entry = load(.helmcode, HelmcodeWebFetchStrategy.cacheScope(deployment)),
                  !entry.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return (deployment, entry.storedAt)
        }
        if entries.count == 1 { return entries[0].deployment }
        guard entries.count == 2 else { return nil }
        return entries.max { $0.storedAt < $1.storedAt }?.deployment
    }

    /// All tenants with a cached session, newest `storedAt` first. Builds the ordered candidate
    /// list for automatic-mode validation.
    public static func cachedTenantsByRecency() -> [HelmcodeDeployment] {
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
        return entries.sorted { $0.storedAt > $1.storedAt }.map(\.deployment)
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

    /// The tenant the selected credential must go to. An explicit selection pins the tenant;
    /// automatic mode detects the host from THAT SAME credential's raw capture and falls back to
    /// Helmcode Cloud for bare headers, so a credential is never sent to both hosts (F1).
    public static func tenant(
        for credential: HelmcodeCredentialSelection,
        deploymentSelection selection: HelmcodeDeploymentSelection) -> HelmcodeDeployment
    {
        if let pinned = selection.pinnedDeployment {
            return pinned
        }
        return Self.detectTenant(fromCookieCapture: credential.rawCapture) ?? .helmcode
    }

    /// The tenant a dashboard link should open, following the same rules as fetching: a pinned
    /// selection wins; otherwise the tenant is detected from the selected credential's own capture
    /// (a manual NaN capture opens NaN even though manual mode never writes the cache); otherwise
    /// the display-path cache detection; else Helmcode Cloud (F4).
    public static func dashboardDeployment(
        settings: HelmcodeProviderSettings?,
        environment: [String: String]) -> HelmcodeDeployment
    {
        let selection = Self.resolveSelection(settings: settings, environment: environment)
        if let pinned = selection.pinnedDeployment {
            return pinned
        }
        // Mirror the fetch rule: when a credential IS selected, its own capture decides — a bare
        // header routes to Helmcode Cloud and never falls through to the cache (G3); only when NO
        // credential is selected does the display-path cache detection decide.
        if let credential = HelmcodeCookieHeader.selectCredential(
            cookieSource: settings?.cookieSource,
            manualCookieHeader: settings?.manualCookieHeader,
            environment: environment)
        {
            return Self.detectTenant(fromCookieCapture: credential.rawCapture) ?? .helmcode
        }
        return Self.detectTenantFromCacheForDisplay() ?? .helmcode
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
