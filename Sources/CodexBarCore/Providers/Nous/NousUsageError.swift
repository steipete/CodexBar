import Foundation

public enum NousUsageError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case authFileInvalid(String)
    case sessionExpired(String)
    case environmentTokenExpired

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Nous Portal login not found. Run `hermes` and sign in to Nous Portal, or set NOUS_PORTAL_ACCESS_TOKEN."
        case let .authFileInvalid(path):
            "Hermes auth file at \(path) has no Nous Portal access token. Run `hermes auth add nous` to sign in."
        case let .sessionExpired(path):
            "Nous Portal access token in \(path) has expired. Run `hermes` so Hermes Agent refreshes it."
        case .environmentTokenExpired:
            "NOUS_PORTAL_ACCESS_TOKEN has expired. Export a fresh token or unset it to use the Hermes Agent login."
        }
    }
}
