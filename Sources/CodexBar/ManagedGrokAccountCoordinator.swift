import CodexBarCore
import Foundation
import Observation

enum ManagedGrokAccountCoordinatorError: Error, Equatable {
    case authenticationInProgress
}

@MainActor
@Observable
final class ManagedGrokAccountCoordinator {
    let service: ManagedGrokAccountService
    private(set) var isAuthenticatingManagedAccount: Bool = false
    private(set) var authenticatingManagedAccountID: UUID?
    private(set) var isRemovingManagedAccount: Bool = false
    private(set) var loginProgressOutput: String?
    var onManagedAccountsDidChange: (@MainActor () -> Void)?

    var hasConflictingManagedAccountOperationInFlight: Bool {
        self.isAuthenticatingManagedAccount || self.isRemovingManagedAccount
    }

    init(service: ManagedGrokAccountService = ManagedGrokAccountService()) {
        self.service = service
    }

    func authenticateManagedAccount(
        existingAccountID: UUID? = nil,
        timeout: TimeInterval = GrokLoginRunner.defaultTimeout,
        onProgress: (@Sendable (String) -> Void)? = nil) async throws -> ManagedGrokAccount
    {
        guard self.isAuthenticatingManagedAccount == false else {
            throw ManagedGrokAccountCoordinatorError.authenticationInProgress
        }

        self.isAuthenticatingManagedAccount = true
        self.authenticatingManagedAccountID = existingAccountID
        self.loginProgressOutput = nil
        defer {
            self.isAuthenticatingManagedAccount = false
            self.authenticatingManagedAccountID = nil
            self.loginProgressOutput = nil
        }

        let account = try await self.service.authenticateManagedAccount(
            existingAccountID: existingAccountID,
            timeout: timeout,
            onProgress: { [weak self] output in
                Task { @MainActor in
                    self?.loginProgressOutput = output
                }
                onProgress?(output)
            })
        self.onManagedAccountsDidChange?()
        return account
    }

    func removeManagedAccount(id: UUID) async throws {
        self.isRemovingManagedAccount = true
        defer { self.isRemovingManagedAccount = false }
        try await self.service.removeManagedAccount(id: id)
        self.onManagedAccountsDidChange?()
    }
}
