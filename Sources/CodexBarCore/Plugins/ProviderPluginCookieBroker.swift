import Foundation

#if os(macOS)
import SweetCookieKit
#endif

final class ProviderPluginCookieBroker: @unchecked Sendable {
    typealias Importer = @Sendable (String) throws -> (header: String, source: String)

    private let provider: UsageProvider
    private let domains: Set<String>
    private let settings: ProviderSettingsSnapshot.CookieProviderSettings
    private let importer: Importer
    private let lock = NSLock()
    private var observed: [String: CookieHeaderCache.Entry] = [:]

    convenience init(provider: UsageProvider, domains: Set<String>, context: ProviderFetchContext) {
        self.init(
            provider: provider,
            domains: domains,
            settings: context.settings.flatMap {
                ProviderDescriptorRegistry.descriptor(for: provider).settingsSection.cookieSettings(from: $0)
            } ?? .init(cookieSource: .auto, manualCookieHeader: nil),
            importer: { domain in
                try Self.importCookieHeader(
                    provider: provider, domain: domain, browserDetection: context.browserDetection)
            })
    }

    init(
        provider: UsageProvider,
        domains: Set<String>,
        settings: ProviderSettingsSnapshot.CookieProviderSettings,
        importer: @escaping Importer)
    {
        self.provider = provider
        self.domains = domains
        self.settings = settings
        self.importer = importer
    }

    var cookieSource: ProviderCookieSource {
        self.settings.cookieSource
    }

    func cookieHeader(domain: String) throws -> String {
        guard self.domains.contains(domain) else {
            throw ProviderPluginError.secretAccess("cookie domain is not declared")
        }
        switch self.settings.cookieSource {
        case .off:
            throw ProviderPluginError.secretAccess("browser cookies are disabled for this provider")
        case .manual:
            guard let header = CookieHeaderNormalizer.normalize(self.settings.manualCookieHeader) else {
                throw ProviderPluginError.secretAccess("the manual cookie header is unavailable")
            }
            return header
        case .auto:
            self.lock.lock()
            defer { self.lock.unlock() }
            if let issued = self.observed[domain] { return issued.cookieHeader }
            let scope = self.scope(domain)
            if let cached = CookieHeaderCache.load(provider: self.provider, scope: scope),
               let header = CookieHeaderNormalizer.normalize(cached.cookieHeader)
            {
                self.observed[domain] = cached
                return header
            }
            let imported = try self.importer(domain)
            guard let header = CookieHeaderNormalizer.normalize(imported.header) else {
                throw ProviderPluginError.secretAccess("no browser session cookies were found")
            }
            // KeychainCacheStore serializes dates as whole-second ISO-8601 values.
            let storedAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            let issued = CookieHeaderCache.Entry(
                cookieHeader: header, storedAt: storedAt, sourceLabel: imported.source)
            self.observed[domain] = issued
            CookieHeaderCache.store(
                provider: self.provider,
                scope: scope,
                cookieHeader: header,
                sourceLabel: issued.sourceLabel,
                now: issued.storedAt)
            return header
        }
    }

    func rejectCookie(domain: String) {
        guard self.settings.cookieSource == .auto,
              let expected = self.lock.withLock({ self.observed[domain] }) else { return }
        CookieHeaderCache.clearIfCurrent(provider: self.provider, scope: self.scope(domain), expected: expected)
    }

    private func scope(_ domain: String) -> CookieHeaderCache.Scope? {
        // Single-domain providers retain their existing cache and manual-refresh behavior.
        self.domains.count == 1 ? nil : .providerVariant(domain)
    }

    static func importCookieHeader(
        provider: UsageProvider? = nil, domain: String, browserDetection: BrowserDetection) throws -> (
        header: String, source: String)
    {
        #if os(macOS)
        let query = BrowserCookieQuery(domains: [domain])
        let client = BrowserCookieClient()
        let order = provider.map { ProviderDefaults.metadata[$0]?.browserCookieOrder ?? Browser.defaultImportOrder }
            ?? [Browser.chrome]
        for browser in order.cookieImportCandidates(using: browserDetection) {
            do {
                let sources = try client.codexBarRecords(matching: query, in: browser)
                for source in sources where !source.records.isEmpty {
                    let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                    let rawHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                    if let header = CookieHeaderNormalizer.normalize(rawHeader) {
                        return (header, source.label)
                    }
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
            }
        }
        throw ProviderPluginError.secretAccess("no Chrome browser session cookies were found")
        #else
        throw ProviderPluginError.secretAccess("browser cookie import is unavailable on this platform")
        #endif
    }
}

public enum UserProviderPluginCookieBroker {
    public static func resolver(
        browserDetection: BrowserDetection) -> ProviderPluginRuntime.InstanceCookieResolver
    {
        { _, domain in
            try ProviderPluginCookieBroker.importCookieHeader(domain: domain, browserDetection: browserDetection).header
        }
    }
}
