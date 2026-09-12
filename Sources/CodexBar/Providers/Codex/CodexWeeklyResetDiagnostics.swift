import Foundation

extension CodexWeeklyResetConfirmation {
    /// Fixed codes only: never include account identities, credit IDs, or provider payloads.
    enum Reason: String, Sendable {
        case candidateCreated
        case sourceNotExactOAuth
        case missingPreviousSnapshot
        case confidenceNotExact
        case invalidObservationTime
        case nonMonotonicObservationTime
        case missingWeeklyWindow
        case invalidWeeklyUsage
        case resetThresholdMismatch
        case invalidResetBoundary
        case inconsistentResetBoundary
        case unsupportedResetBoundary
        case accountMismatch
        case planMismatch
        case missingCreditInventory
        case invalidCreditObservationTime
        case nonMonotonicCreditObservationTime
        case inconsistentAvailableCreditCount
        case changedCreditInventory
        case evidenceVersionMismatch
        case futureCandidate
        case expiredCandidate
        case staleObservation
        case minimumDelay
        case confirmedObservation
    }

    enum CandidateCreation: Sendable {
        case created(CodexWeeklyResetPublicationCandidate)
        case rejected(Reason)

        var candidate: CodexWeeklyResetPublicationCandidate? {
            guard case let .created(candidate) = self else { return nil }
            return candidate
        }

        var reason: Reason {
            switch self {
            case .created: .candidateCreated
            case let .rejected(reason): reason
            }
        }
    }

    struct DelayedEvaluation: Equatable, Sendable {
        let decision: DelayedCandidateDecision
        let reason: Reason
    }
}

extension UsageStore {
    enum CodexWeeklyResetPersistenceDecision: String, Sendable {
        case missingExpectedGuard
        case accountChanged
        case ambiguousActiveAccount
        case existingAccountChanged
        case noCandidateChange
        case missingCandidateOrBaseline
        case storeUnavailable
        case storeRequested

        var diagnosticMetadata: [String: String] {
            ["stage": "candidatePersistence", "decision": self.rawValue]
        }
    }
}
