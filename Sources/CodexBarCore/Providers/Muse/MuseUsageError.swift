import Foundation

public enum MuseUsageError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case invalidCredentials
    case keychainUnavailable
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Muse Code login not found. Run `muse login`, then refresh CodexBar."
        case .invalidCredentials:
            "Muse Code login was rejected. Run `muse login` again."
        case .keychainUnavailable:
            "Muse Code credentials are in Keychain but could not be read without a prompt."
        case let .parseFailed(message):
            "Could not parse Muse Code login: \(message)"
        }
    }
}
