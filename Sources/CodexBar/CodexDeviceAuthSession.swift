import CodexBarCore
import Foundation
import Observation

/// Observable session state for the Codex device-auth sheet.
///
/// Owned by `ManagedCodexAccountCoordinator` for the lifetime of one
/// device-auth attempt. SwiftUI's `.sheet(item:)` binds to this session via
/// `Identifiable`, so clearing the coordinator's `activeDeviceAuthSession`
/// reference automatically dismisses the sheet.
@MainActor
@Observable
final class CodexDeviceAuthSession: Identifiable {
    enum Phase: Equatable {
        case requestingCode
        case awaitingUser(userCode: String, verificationURL: URL)
        case exchangingTokens
        case failed(String)
    }

    let id = UUID()
    private(set) var phase: Phase = .requestingCode
    // Stored as a type-erased closure because the two auth paths (managed
    // returns `ManagedCodexAccount`, ambient returns `Void`) produce Tasks
    // with different success types, and we only need a way to cancel.
    private var cancelOwningTask: (() -> Void)?

    /// Cancels the underlying authentication task. Tasks that observe
    /// cancellation surface a `CancellationError`, which callers should treat
    /// as a benign user-initiated abort (no notice shown).
    func cancel() {
        self.cancelOwningTask?()
    }

    func update(_ phase: Phase) {
        self.phase = phase
    }

    /// Projects a `ManagedCodexDeviceFlowProgress` from the service into the
    /// sheet's phase. Terminal-failure cases are produced by the coordinator
    /// (which holds the error), not the service, so only non-terminal phases
    /// arrive here.
    func applyProgress(_ progress: ManagedCodexDeviceFlowProgress) {
        switch progress {
        case .requestingCode:
            self.phase = .requestingCode
        case let .awaitingUser(userCode, verificationURL):
            self.phase = .awaitingUser(userCode: userCode, verificationURL: verificationURL)
        case .exchangingTokens:
            self.phase = .exchangingTokens
        }
    }

    func attach<Success: Sendable>(task: Task<Success, Error>) {
        self.cancelOwningTask = { task.cancel() }
    }
}
