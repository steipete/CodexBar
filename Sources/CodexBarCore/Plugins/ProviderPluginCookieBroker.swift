#if canImport(JavaScriptCore)
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
        let cookieSettings = settings?.pluginCookieSettings(for: provider)
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

extension ProviderSettingsSnapshot {
    // Centralizes the provider-specific settings shape at the cookie broker boundary.
    // swiftlint:disable:next cyclomatic_complexity
    fileprivate func pluginCookieSettings(for provider: UsageProvider) -> PluginCookieSettings? {
        switch provider {
        case .cursor: self.cursor.map(PluginCookieSettings.init)
        case .opencode: self.opencode.map {
                PluginCookieSettings(cookieSource: $0.cookieSource, manualCookieHeader: $0.manualCookieHeader)
            }
        case .opencodego: self.opencodego.map {
                PluginCookieSettings(cookieSource: $0.cookieSource, manualCookieHeader: $0.manualCookieHeader)
            }
        case .alibaba: self.alibaba.map {
                PluginCookieSettings(cookieSource: $0.cookieSource, manualCookieHeader: $0.manualCookieHeader)
            }
        case .alibabatokenplan: self.alibabaTokenPlan.map(PluginCookieSettings.init)
        case .qwencloud: self.qwenCloud.map(PluginCookieSettings.init)
        case .factory: self.factory.map(PluginCookieSettings.init)
        case .minimax: self.minimax.map {
                PluginCookieSettings(cookieSource: $0.cookieSource, manualCookieHeader: $0.manualCookieHeader)
            }
        case .manus: self.manus.map(PluginCookieSettings.init)
        case .copilot: self.copilot.map {
                PluginCookieSettings(
                    cookieSource: $0.budgetCookieSource,
                    manualCookieHeader: $0.manualBudgetCookieHeader)
            }
        case .kimi: self.kimi.map(PluginCookieSettings.init)
        case .longcat: self.longcat.map(PluginCookieSettings.init)
        case .augment: self.augment.map(PluginCookieSettings.init)
        case .amp: self.amp.map(PluginCookieSettings.init)
        case .t3chat: self.t3chat.map(PluginCookieSettings.init)
        case .zoommate: self.zoommate.map(PluginCookieSettings.init)
        case .notion: self.notion.map {
                PluginCookieSettings(cookieSource: $0.cookieSource, manualCookieHeader: $0.manualCookieHeader)
            }
        case .commandcode: self.commandcode.map(PluginCookieSettings.init)
        case .ollama: self.ollama.map(PluginCookieSettings.init)
        case .windsurf: self.windsurf.map {
                PluginCookieSettings(cookieSource: $0.cookieSource, manualCookieHeader: $0.manualCookieHeader)
            }
        case .perplexity: self.perplexity.map(PluginCookieSettings.init)
        case .mimo: self.mimo.map(PluginCookieSettings.init)
        case .abacus: self.abacus.map(PluginCookieSettings.init)
        case .mistral: self.mistral.map(PluginCookieSettings.init)
        case .qoder: self.qoder.map(PluginCookieSettings.init)
        case .stepfun: self.stepfun.map {
                PluginCookieSettings(cookieSource: $0.cookieSource, manualCookieHeader: $0.manualToken)
            }
        default: nil
        }
    }
}

private struct PluginCookieSettings: ProviderCookieSettings {
    let cookieSource: ProviderCookieSource
    let manualCookieHeader: String?

    init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
    }

    init(_ settings: some ProviderCookieSettings) {
        self.init(cookieSource: settings.cookieSource, manualCookieHeader: settings.manualCookieHeader)
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
#endif
