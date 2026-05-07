import Foundation

enum OpenCodeWebCookieSupport {
    private static let requestCookieNames: Set<String> = ["auth", "__Host-auth"]

    struct Context {
        let settings: ProviderSettingsSnapshot.OpenCodeProviderSettings?
        let provider: UsageProvider
        let browserDetection: BrowserDetection
        let allowCached: Bool
    }

    static func requestCookieHeader(from rawHeader: String?) -> String? {
        CookieHeaderNormalizer.filteredHeader(from: rawHeader, allowedNames: self.requestCookieNames)
    }

    static func resolveCookieHeader(
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
