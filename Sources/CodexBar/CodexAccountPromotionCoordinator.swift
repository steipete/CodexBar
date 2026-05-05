import Foundation
import Observation

struct CodexSystemAccountPromotionUserFacingError: Error, Equatable {
    let title: String
    let message: String
}

@MainActor
@Observable
final class CodexAccountPromotionCoordinator {
    let service: CodexAccountPromotionService
    weak var managedAccountCoordinator: ManagedCodexAccountCoordinator?
    private(set) var isAuthenticatingLiveAccount = false
    private(set) var isPromotingSystemAccount = false
    private(set) var userFacingError: CodexSystemAccountPromotionUserFacingError?

    init(
        service: CodexAccountPromotionService,
        managedAccountCoordinator: ManagedCodexAccountCoordinator? = nil)
    {
        self.service = service
        self.managedAccountCoordinator = managedAccountCoordinator
    }

    convenience init(
        settingsStore: SettingsStore,
        usageStore: UsageStore,
        managedAccountCoordinator: ManagedCodexAccountCoordinator? = nil)
    {
        self.init(
            service: CodexAccountPromotionService(settingsStore: settingsStore, usageStore: usageStore),
            managedAccountCoordinator: managedAccountCoordinator)
    }

    func promote(managedAccountID: UUID)
        async -> Result<CodexAccountPromotionResult, CodexSystemAccountPromotionUserFacingError>
    {
        self.userFacingError = nil

        guard !self.isInteractionBlocked() else {
            let error = Self.interactionBlockedError()
            self.userFacingError = error
            return .failure(error)
        }

        self.isPromotingSystemAccount = true
        defer { self.isPromotingSystemAccount = false }

        do {
            let result = try await self.service.promoteManagedAccount(id: managedAccountID)
            return .success(result)
        } catch {
            let mapped = Self.mapUserFacingError(error)
            self.userFacingError = mapped
            return .failure(mapped)
        }
    }

    func clearError() {
        self.userFacingError = nil
    }

    func setLiveReauthenticationInProgress(_ isInProgress: Bool) {
        self.isAuthenticatingLiveAccount = isInProgress
    }

    func isInteractionBlocked() -> Bool {
        self.isPromotingSystemAccount ||
            self.isAuthenticatingLiveAccount ||
            self.managedAccountCoordinator?.hasConflictingManagedAccountOperationInFlight == true
    }

    private static func interactionBlockedError() -> CodexSystemAccountPromotionUserFacingError {
        CodexSystemAccountPromotionUserFacingError(
            title: "Could not switch system account",
            message: "Finish the current managed account change before switching the system account.")
    }

    static func mapUserFacingError(_ error: Error) -> CodexSystemAccountPromotionUserFacingError {
        let title = "Could not switch system account"

        if let error = error as? CodexAccountPromotionError {
            let message = switch error {
            case .targetManagedAccountNotFound:
                "That account is no longer available in CodexBar. Refresh the account list and try again."
            case .targetManagedAccountAuthMissing:
                "CodexBar could not find saved auth for that account. Re-authenticate it and try again."
            case .targetManagedAccountAuthUnreadable:
                "CodexBar could not read saved auth for that account. Re-authenticate it and try again."
            case .liveAccountUnreadable:
                "CodexBar could not read the current system account on this Mac."
            case .liveAccountMissingIdentityForPreservation:
                "CodexBar could not safely preserve the current system account before switching."
            case .liveAccountAPIKeyOnlyUnsupported:
                "CodexBar can't replace a system account that is signed in with an API key only setup."
            case .displacedLiveManagedAccountConflict:
                "CodexBar found another managed account that already uses the current system account. "
                    + "Resolve the duplicate account before switching."
            case .displacedLiveImportFailed:
                "CodexBar could not save the current system account before switching."
            case .managedStoreCommitFailed:
                "CodexBar could not update managed account storage."
            case .liveAuthSwapFailed:
                "CodexBar could not replace the live Codex auth on this Mac."
            }

            return CodexSystemAccountPromotionUserFacingError(title: title, message: message)
        }

        return CodexSystemAccountPromotionUserFacingError(title: title, message: error.localizedDescription)
    }
}
