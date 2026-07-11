import Foundation
import SweetCookieKit

#if os(macOS)

private let factoryAPIKeyCookieImportOrder: BrowserCookieImportOrder =
    ProviderDefaults.metadata[.factory]?.browserCookieOrder ?? Browser.defaultImportOrder

public enum FactoryStatusProbeError: LocalizedError, Sendable, Equatable {
    case notLoggedIn
    case missingAPIKey
    case unauthorizedAPIKey
    case networkError(String)
    case parseFailed(String)
    case noSessionCookie

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            "No usable Droid session found. Log in to app.factory.ai in \(factoryAPIKeyCookieImportOrder.loginHint), " +
                "then refresh Droid."
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
            "No Factory session found. Please log in to app.factory.ai in \(factoryAPIKeyCookieImportOrder.loginHint)."
        }
    }
}

#else

public enum FactoryStatusProbeError: LocalizedError, Sendable, Equatable {
    case notSupported
    case missingAPIKey
    case unauthorizedAPIKey

    public var errorDescription: String? {
        switch self {
        case .notSupported:
            "Factory is only supported on macOS."
        case .missingAPIKey:
            "Droid API key missing. Set FACTORY_API_KEY or run `codexbar config set-api-key --provider factory`."
        case .unauthorizedAPIKey:
            "Droid API authentication failed (401/403). Refresh FACTORY_API_KEY."
        }
    }
}

#endif
