import Foundation
import SweetCookieKit

#if os(macOS)
extension CursorStatusProbe {
    /// Whether the application maps to a browser whose Cursor cookie source can be inspected without prompting.
    public static func supportsInteractiveLoginBrowser(
        applicationURL: URL?,
        browserDetection: BrowserDetection) -> Bool
    {
        guard let applicationURL,
              let browser = self.interactiveBrowser(forApplicationURL: applicationURL)
        else {
            return false
        }
        return CursorCookieImporter.isInteractiveLoginSourceAvailable(
            browser: browser,
            applicationURL: applicationURL,
            browserDetection: browserDetection)
    }

    static func interactiveBrowser(forApplicationURL applicationURL: URL) -> Browser? {
        self.interactiveBrowser(bundleIdentifier: Bundle(url: applicationURL)?.bundleIdentifier)
    }

    static func interactiveBrowser(bundleIdentifier: String?) -> Browser? {
        let normalized = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.flatMap { Self.interactiveBrowserByBundleIdentifier[$0] }
    }

    /// Bind the launched app to the exact SweetCookieKit store CodexBar will read. Display names
    /// and `.app` filenames are user-editable and can otherwise route a login to unrelated cookies.
    /// SweetCookieKit does not expose bundle identifiers, so keep only unambiguous one-to-one
    /// mappings here; unknown or ambiguous browser channels deliberately fail closed.
    static let interactiveBrowserByBundleIdentifier: [String: Browser] = [
        "ai.perplexity.comet": .comet,
        "app.zen-browser.zen": .zen,
        "at.studio.asidebrowser": .aside,
        "com.apple.safari": .safari,
        "com.brave.browser": .brave,
        "com.brave.browser.beta": .braveBeta,
        "com.brave.browser.nightly": .braveNightly,
        "com.google.chrome": .chrome,
        "com.google.chrome.beta": .chromeBeta,
        "com.google.chrome.canary": .chromeCanary,
        "com.microsoft.edgemac": .edge,
        "com.microsoft.edgemac.beta": .edgeBeta,
        "com.microsoft.edgemac.canary": .edgeCanary,
        "com.openai.atlas": .chatgptAtlas,
        "com.operasoftware.opera": .opera,
        "com.operasoftware.operaneon": .operaNeon,
        "com.vivaldi.vivaldi": .vivaldi,
        "company.thebrowser.browser": .arc,
        "company.thebrowser.dia": .dia,
        "net.imput.helium": .helium,
        "org.chromium.chromium": .chromium,
        "org.mozilla.firefox": .firefox,
        "org.mozilla.firefox.beta": .firefoxBeta,
        "org.mozilla.firefoxdeveloperedition": .firefoxDeveloperEdition,
        "org.mozilla.nightly": .firefoxNightly,
    ]
}
#endif
