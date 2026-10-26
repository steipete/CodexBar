import Foundation

extension UsageStore {
    enum ClaudeOAuthActiveAccountObservation: Equatable, Sendable {
        case stable(identity: String?)
        case changed
    }

    struct ClaudeOAuthAccountBindingCandidate: Codable, Equatable {
        let identity: String
        let observedAt: Date
    }

    struct ClaudeOAuthHistoryEvidence {
        let owner: String
        let persistentRefHash: String?
        let keychainCredentialMismatch: Bool
        let keychainCredentialAbsent: Bool
        let keychainCredentialUnavailable: Bool
        let activeAccountObservation: ClaudeOAuthActiveAccountObservation
        let observedAt: Date
    }
}
