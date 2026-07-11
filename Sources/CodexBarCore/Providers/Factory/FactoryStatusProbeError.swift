import Foundation
#if os(macOS)
import SweetCookieKit

private let factoryAPIKeyCookieImportOrder: BrowserCookieImportOrder =
    ProviderDefaults.metadata[.factory]?.browserCookieOrder ?? Browser.defaultImportOrder
#endif

public enum FactoryStatusProbeError: LocalizedError, Sendable, Equatable {
    case notSupported
    case notLoggedIn
    case missingAPIKey
    case unauthorizedAPIKey
    case networkError(String)
    case parseFailed(String)
    case noSessionCookie

    public var errorDescription: String? {
        switch self {
        case .notSupported:
            "Factory browser-cookie auth is only supported on macOS. Use FACTORY_API_KEY / --source api on Linux."
        case .notLoggedIn:
            #if os(macOS)
            "No usable Droid session found. Log in to app.factory.ai in \(factoryAPIKeyCookieImportOrder.loginHint), " +
                "then refresh Droid."
            #else
            "No usable Droid session found. Log in to app.factory.ai, then refresh Droid."
            #endif
        case .missingAPIKey:
            "Droid API key missing. Set FACTORY_API_KEY, add providers[].apiKey for factory in " +
                "~/.codexbar/config.json, or run `codexbar config set-api-key --provider factory`."
        case .unauthorizedAPIKey:
            "Droid API authentication failed (401/403). Refresh FACTORY_API_KEY or regenerate a key at " +
                "app.factory.ai/settings/api-keys."
        case let .networkError(msg):
            "Factory API error: \(msg)"
        case let .parseFailed(msg):
            "Could not parse Factory usage: \(msg)"
        case .noSessionCookie:
            #if os(macOS)
            "No Factory session found. Please log in to app.factory.ai in \(factoryAPIKeyCookieImportOrder.loginHint)."
            #else
            "No Factory session found. Please log in to app.factory.ai."
            #endif
        }
    }
}
