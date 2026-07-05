import Foundation

extension ProviderBrowserCookieDefaults {
    /// DeepSeek platform sessions are normally in Chrome; keep automatic import narrow.
    public static var deepSeekCookieImportOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        [.chrome]
        #else
        nil
        #endif
    }
}
