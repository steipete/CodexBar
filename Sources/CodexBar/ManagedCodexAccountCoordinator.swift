import CodexBarCore
import Foundation
import Observation

enum ManagedCodexAccountCoordinatorError: Error, Equatable {
    case authenticationInProgress
}

@MainActor
@Observable
final class ManagedCodexAccountCoordinator {
    let service: ManagedCodexAccountService
    private(set) var isAuthenticatingManagedAccount: Bool = false
    private(set) var authenticatingManagedAccountID: UUID?
    private(set) var isRemovingManagedAccount: Bool = false
    private(set) var removingManagedAccountID: UUID?
    /// Non-nil while a device-auth sheet is on screen. SwiftUI's
    /// `.sheet(item:)` observes this; clearing it dismisses the sheet.
    private(set) var activeDeviceAuthSession: CodexDeviceAuthSession?
    var onManagedAccountsDidChange: (@MainActor () -> Void)?

    var hasConflictingManagedAccountOperationInFlight: Bool {
        self.isAuthenticatingManagedAccount || self.isRemovingManagedAccount
    }

    init(service: ManagedCodexAccountService = ManagedCodexAccountService()) {
        self.service = service
    }

    func authenticateManagedAccount(
        existingAccountID: UUID? = nil,
        timeout: TimeInterval = 120)
        async throws -> ManagedCodexAccount
    {
        guard self.isAuthenticatingManagedAccount == false else {
            throw ManagedCodexAccountCoordinatorError.authenticationInProgress
        }

        self.isAuthenticatingManagedAccount = true
        self.authenticatingManagedAccountID = existingAccountID
        defer {
            self.isAuthenticatingManagedAccount = false
            self.authenticatingManagedAccountID = nil
        }

        let account = try await self.service.authenticateManagedAccount(
            existingAccountID: existingAccountID,
            timeout: timeout)
        self.onManagedAccountsDidChange?()
        return account
    }

    /// Authenticates a managed Codex account using the native device-auth
    /// flow. Owns the `CodexDeviceAuthSession` for the sheet and reuses the
    /// existing `isAuthenticatingManagedAccount` guard so the browser path
    /// and the device path are mutually exclusive.
    func authenticateManagedAccountWithDeviceFlow(
        existingAccountID: UUID? = nil,
        sessionTimeout: TimeInterval = 15 * 60)
        async throws -> ManagedCodexAccount
    {
        guard self.isAuthenticatingManagedAccount == false else {
            throw ManagedCodexAccountCoordinatorError.authenticationInProgress
        }

        let session = CodexDeviceAuthSession()
        self.isAuthenticatingManagedAccount = true
        self.authenticatingManagedAccountID = existingAccountID
        self.activeDeviceAuthSession = session
        defer {
            self.isAuthenticatingManagedAccount = false
            self.authenticatingManagedAccountID = nil
            self.activeDeviceAuthSession = nil
        }

        let task = Task<ManagedCodexAccount, Error> { [service, session] in
            try await service.authenticateManagedAccountWithDeviceFlow(
                existingAccountID: existingAccountID,
                sessionTimeout: sessionTimeout,
                progress: { phase in
                    session.applyProgress(phase)
                })
        }
        session.attach(task: task)

        do {
            let account = try await task.value
            self.onManagedAccountsDidChange?()
            return account
        } catch {
            throw error
        }
    }

    /// Runs the native device-auth flow against the ambient Codex home
    /// (`~/.codex/auth.json`), for re-authenticating the system/live Codex
    /// account without invoking the `codex login` CLI.
    ///
    /// Unlike the managed variant, this path does not mutate the managed
    /// account store. The pane is expected to toggle
    /// `isAuthenticatingLiveCodexAccount` for UI disable/enable state, same
    /// as the existing ambient browser path.
    func authenticateAmbientCodexAccountWithDeviceFlow(
        sessionTimeout: TimeInterval = 15 * 60)
        async throws
    {
        guard self.activeDeviceAuthSession == nil else {
            throw ManagedCodexAccountCoordinatorError.authenticationInProgress
        }

        let session = CodexDeviceAuthSession()
        self.activeDeviceAuthSession = session
        defer {
            self.activeDeviceAuthSession = nil
        }

        let task = Task<Void, Error> { [service, session] in
            try await service.authenticateAmbientCodexAccountWithDeviceFlow(
                sessionTimeout: sessionTimeout,
                progress: { phase in
                    session.applyProgress(phase)
                })
        }
        session.attach(task: task)

        try await task.value
        self.onManagedAccountsDidChange?()
    }

    func removeManagedAccount(id: UUID) async throws {
        self.isRemovingManagedAccount = true
        self.removingManagedAccountID = id
        defer {
            self.isRemovingManagedAccount = false
            self.removingManagedAccountID = nil
        }

        try await self.service.removeManagedAccount(id: id)
        self.onManagedAccountsDidChange?()
    }
}
