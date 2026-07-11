import Foundation

public enum OpenCodeWebCookieSupport {
    private static let requestCookieNames: Set<String> = ["auth", "__Host-auth"]

    public struct Context {
        public let settings: ProviderSettingsSnapshot.OpenCodeProviderSettings?
        public let provider: UsageProvider
        public let browserDetection: BrowserDetection
        public let allowCached: Bool

        public init(
            settings: ProviderSettingsSnapshot.OpenCodeProviderSettings?,
            provider: UsageProvider,
            browserDetection: BrowserDetection,
            allowCached: Bool)
        {
            self.settings = settings
            self.provider = provider
            self.browserDetection = browserDetection
            self.allowCached = allowCached
        }
    }

    public static func requestCookieHeader(from rawHeader: String?) -> String? {
        CookieHeaderNormalizer.filteredHeader(from: rawHeader, allowedNames: self.requestCookieNames)
    }

    public static func resolveCookieHeader(
        context: Context,
        invalidCookie: @autoclosure () -> Error,
        missingCookie: @autoclosure () -> Error) throws -> String
    {
        if let settings = context.settings, settings.cookieSource == .manual {
            if let header = self.requestCookieHeader(from: settings.manualCookieHeader) {
                return header
            }
            throw invalidCookie()
        }

        #if os(macOS)
        if context.allowCached,
           let cached = CookieHeaderCache.load(provider: context.provider),
           let header = self.requestCookieHeader(from: cached.cookieHeader)
        {
            return header
        }
        let session = try OpenCodeCookieImporter.importSession(browserDetection: context.browserDetection)
        guard let header = self.requestCookieHeader(from: session.cookieHeader) else {
            throw missingCookie()
        }
        CookieHeaderCache.store(
            provider: context.provider,
            cookieHeader: header,
            sourceLabel: session.sourceLabel)
        return header
        #else
        throw missingCookie()
        #endif
    }
}
