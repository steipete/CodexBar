import CodexBarCore
import Foundation

enum CodexDisplacedLivePreservationNoneReason: Equatable {
    case liveMissing
    case targetMatchesLiveAuthIdentity
}

enum CodexDisplacedLivePreservationRejectReason: Equatable {
    case liveUnreadable
    case liveAPIKeyOnlyUnsupported
    case liveIdentityMissingForPreservation
    case conflictingReadableManagedHome
}

enum CodexDisplacedLivePreservationImportReason: Equatable {
    case noExistingManagedDestination
}

enum CodexDisplacedLivePreservationRefreshReason: Equatable {
    case readableHomeIdentityMatch
    case readableHomeIdentityMatchUsingPersistedEmailFallback
}

enum CodexDisplacedLivePreservationRepairReason: Equatable {
    case persistedProviderMatchWithMissingHome
    case persistedProviderMatchWithUnreadableHome
    case persistedLegacyEmailMatch
}

enum CodexDisplacedLivePreservationPlan {
    case none(reason: CodexDisplacedLivePreservationNoneReason)
    case reject(reason: CodexDisplacedLivePreservationRejectReason)
    case importNew(reason: CodexDisplacedLivePreservationImportReason)
    case refreshExisting(
        destination: PreparedStoredManagedAccount,
        reason: CodexDisplacedLivePreservationRefreshReason)
    case repairExisting(
        destination: PreparedStoredManagedAccount,
        reason: CodexDisplacedLivePreservationRepairReason)
}

struct CodexDisplacedLivePreservationPlanner {
    func makePlan(context: PreparedPromotionContext) -> CodexDisplacedLivePreservationPlan {
        switch context.live.homeState {
        case .missing:
            return .none(reason: .liveMissing)
        case .unreadable:
            return .reject(reason: .liveUnreadable)
        case .apiKeyOnly:
            return .reject(reason: .liveAPIKeyOnlyUnsupported)
        case .readable:
            break
        }

        guard let liveAuthIdentity = context.live.authIdentity else {
            return .reject(reason: .liveIdentityMissingForPreservation)
        }

        if let targetAuthIdentity = context.target.authIdentity,
           CodexIdentityMatcher.matches(
               targetAuthIdentity.identity,
               lhsEmail: targetAuthIdentity.email,
               liveAuthIdentity.identity,
               rhsEmail: liveAuthIdentity.email)
        {
            return .none(reason: .targetMatchesLiveAuthIdentity)
        }

        let candidates = context.storedManagedAccounts.filter { $0.persisted.id != context.target.persisted.id }
        if let destination = self.findReadableHomeMatch(in: candidates, liveAuthIdentity: liveAuthIdentity) {
            let reason: CodexDisplacedLivePreservationRefreshReason =
                if liveAuthIdentity.email == nil {
                    .readableHomeIdentityMatchUsingPersistedEmailFallback
                } else {
                    .readableHomeIdentityMatch
                }
            return .refreshExisting(destination: destination, reason: reason)
        }

        if self.hasConflictingReadableHome(in: candidates, liveAuthIdentity: liveAuthIdentity) {
            return .reject(reason: .conflictingReadableManagedHome)
        }

        if let repaired = self.findPersistedRepairMatch(in: candidates, liveAuthIdentity: liveAuthIdentity) {
            return .repairExisting(destination: repaired.destination, reason: repaired.reason)
        }

        guard liveAuthIdentity.identity != .unresolved, liveAuthIdentity.email != nil else {
            return .reject(reason: .liveIdentityMissingForPreservation)
        }

        return .importNew(reason: .noExistingManagedDestination)
    }

    private func findReadableHomeMatch(
        in candidates: [PreparedStoredManagedAccount],
        liveAuthIdentity: PreparedIdentity)
        -> PreparedStoredManagedAccount?
    {
        candidates.first { candidate in
            guard let candidateAuthIdentity = candidate.authIdentity else { return false }
            return CodexIdentityMatcher.matches(
                candidateAuthIdentity.identity,
                lhsEmail: candidateAuthIdentity.email,
                liveAuthIdentity.identity,
                rhsEmail: liveAuthIdentity.email)
        }
    }

    private func findPersistedRepairMatch(
        in candidates: [PreparedStoredManagedAccount],
        liveAuthIdentity: PreparedIdentity)
        -> (destination: PreparedStoredManagedAccount, reason: CodexDisplacedLivePreservationRepairReason)?
    {
        switch liveAuthIdentity.identity {
        case let .providerAccount(id):
            let providerAccountID = ManagedCodexAccount.normalizeProviderAccountID(id)
            if let destination = candidates.first(where: {
                guard $0.persisted.providerAccountID == providerAccountID else { return false }
                guard let liveEmail = liveAuthIdentity.email else { return true }
                return $0.persisted.email == liveEmail
            }),
                let reason = self.providerRepairReason(for: destination)
            {
                return (destination, reason)
            }

            if let liveEmail = liveAuthIdentity.email,
               let destination = candidates.first(where: {
                   $0.persisted.providerAccountID == nil && $0.persisted.email == liveEmail
               })
            {
                return (destination, .persistedLegacyEmailMatch)
            }

            return nil

        case let .emailOnly(normalizedEmail):
            guard let destination = candidates.first(where: {
                $0.persisted.providerAccountID == nil && $0.persisted.email == normalizedEmail
            }) else {
                return nil
            }
            return (destination, .persistedLegacyEmailMatch)

        case .unresolved:
            return nil
        }
    }

    private func hasConflictingReadableHome(
        in candidates: [PreparedStoredManagedAccount],
        liveAuthIdentity: PreparedIdentity)
        -> Bool
    {
        guard case let .providerAccount(id) = liveAuthIdentity.identity else {
            return false
        }

        let providerAccountID = ManagedCodexAccount.normalizeProviderAccountID(id)
        return candidates.contains { candidate in
            guard candidate.persisted.providerAccountID == providerAccountID else { return false }
            if let liveEmail = liveAuthIdentity.email, candidate.persisted.email != liveEmail {
                return false
            }
            guard case .readable = candidate.homeState else { return false }
            guard let candidateAuthIdentity = candidate.authIdentity else { return false }
            return !CodexIdentityMatcher.matches(
                candidateAuthIdentity.identity,
                lhsEmail: candidateAuthIdentity.email,
                liveAuthIdentity.identity,
                rhsEmail: liveAuthIdentity.email)
        }
    }

    private func providerRepairReason(
        for destination: PreparedStoredManagedAccount)
        -> CodexDisplacedLivePreservationRepairReason?
    {
        switch destination.homeState {
        case .missing:
            .persistedProviderMatchWithMissingHome
        case .unreadable:
            .persistedProviderMatchWithUnreadableHome
        case .readable:
            nil
        }
    }
}
