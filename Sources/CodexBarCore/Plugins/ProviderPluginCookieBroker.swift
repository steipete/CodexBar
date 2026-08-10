import Foundation

#if os(macOS)
import SweetCookieKit
#endif

enum ProviderPluginCookieBroker {
    static func resolver(context: ProviderFetchContext) -> ProviderPluginRuntime.CookieResolver {
        let settings = context.settings
        let browserDetection = context.browserDetection
        return { provider, domain in
            try self.cookieHeader(
                provider: provider,
                domain: domain,
                settings: settings,
                browserDetection: browserDetection)
        }
    }

    private static func cookieHeader(
        provider: UsageProvider,
        domain: String,
        settings: ProviderSettingsSnapshot?,
        browserDetection: BrowserDetection) throws -> String
    {
        let cookieSettings = settings.flatMap {
            ProviderDescriptorRegistry.descriptor(for: provider).settingsSection.cookieSettings(from: $0)
        }
        switch cookieSettings?.cookieSource ?? .auto {
        case .off:
            throw ProviderPluginError.secretAccess("browser cookies are disabled for this provider")
        case .manual:
            guard let header = CookieHeaderNormalizer.normalize(cookieSettings?.manualCookieHeader) else {
                throw ProviderPluginError.secretAccess("the manual cookie header is unavailable")
            }
            return header
        case .auto:
            if let cached = CookieHeaderCache.load(provider: provider),
               let header = CookieHeaderNormalizer.normalize(cached.cookieHeader)
            {
                return header
            }
            return try self.importCookieHeader(
                provider: provider,
                domain: domain,
                browserDetection: browserDetection)
        }
    }

    private static func importCookieHeader(
        provider: UsageProvider,
        domain: String,
        browserDetection: BrowserDetection) throws -> String
    {
        #if os(macOS)
        let importOrder = ProviderDefaults.metadata[provider]?.browserCookieOrder ?? Browser.defaultImportOrder
        let query = BrowserCookieQuery(domains: [domain])
        let client = BrowserCookieClient()
        for browser in importOrder.cookieImportCandidates(using: browserDetection) {
            do {
                let sources = try client.codexBarRecords(matching: query, in: browser)
                for source in sources where !source.records.isEmpty {
                    let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                    let rawHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                    guard let header = CookieHeaderNormalizer.normalize(rawHeader) else { continue }
                    CookieHeaderCache.store(provider: provider, cookieHeader: header, sourceLabel: source.label)
                    return header
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
            }
        }
        throw ProviderPluginError.secretAccess("no browser session cookies were found")
        #else
        _ = provider
        _ = domain
        _ = browserDetection
        throw ProviderPluginError.secretAccess("browser cookie import is unavailable on this platform")
        #endif
    }
}

public enum UserProviderPluginCookieBroker {
    public static func resolver(
        browserDetection: BrowserDetection) -> ProviderPluginRuntime.InstanceCookieResolver
    {
        { _, domain in
            #if os(macOS)
            let query = BrowserCookieQuery(domains: [domain])
            let client = BrowserCookieClient()
            for browser in [Browser.chrome].cookieImportCandidates(using: browserDetection) {
                do {
                    let sources = try client.codexBarRecords(matching: query, in: browser)
                    for source in sources where !source.records.isEmpty {
                        let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                        let rawHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                        if let header = CookieHeaderNormalizer.normalize(rawHeader) {
                            return header
                        }
                    }
                } catch {
                    BrowserCookieAccessGate.recordIfNeeded(error)
                }
            }
            throw ProviderPluginError.secretAccess("no Chrome browser session cookies were found")
            #else
            _ = domain
            throw ProviderPluginError.secretAccess("browser cookie import is unavailable on this platform")
            #endif
        }
    }
}
