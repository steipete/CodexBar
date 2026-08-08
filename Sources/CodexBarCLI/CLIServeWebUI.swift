import CodexBarCore
import Foundation

enum CLIServeWebUI {
    static func response() -> CLILocalHTTPResponse {
        CLILocalHTTPResponse(
            status: .ok,
            body: Data(self.renderedHTML.utf8),
            contentType: "text/html; charset=utf-8",
            extraHeaders: [("Cache-Control", "no-store")])
    }

    /// Serves an embedded provider brand icon for the web dashboard. Icons are
    /// static brand art without account data, so the route needs no auth; they
    /// are immutable per binary, so clients may cache them aggressively.
    static func iconResponse(name: String) -> CLILocalHTTPResponse? {
        guard let base64 = CLIServeProviderIcons.base64ByResourceName[name],
              let data = Data(base64Encoded: base64)
        else {
            return nil
        }
        return CLILocalHTTPResponse(
            status: .ok,
            body: data,
            contentType: "image/svg+xml",
            extraHeaders: [("Cache-Control", "public, max-age=86400, immutable")])
    }

    /// Provider-id → icon URL map injected into the page. Only providers whose
    /// descriptor icon is actually embedded appear; the UI falls back to a
    /// neutral dot for the rest.
    private static let renderedHTML: String = {
        var icons: [String: String] = [:]
        for provider in UsageProvider.allCases {
            let resource = ProviderDescriptorRegistry.descriptor(for: provider).branding.iconResourceName
            if CLIServeProviderIcons.base64ByResourceName[resource] != nil {
                icons[provider.rawValue] = "/icons/\(resource).svg"
            }
        }
        let encoder = JSONEncoder()
        // Sorted for deterministic output; unescaped slashes keep the inline
        // script readable and the URLs greppable in tests.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(icons)).flatMap { String(bytes: $0, encoding: .utf8) } ?? "{}"
        return html.replacingOccurrences(of: "__PROVIDER_ICON_URLS__", with: json)
    }()
}
