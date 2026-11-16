import Foundation

/// Describes which local sources are represented by a token-cost snapshot.
///
/// Claude and Codex can read Pi/OMP session logs as an inclusive convenience. The
/// spend dashboard uses this metadata to project the native portion when Pi is
/// shown as its own source, so the same session is never counted twice.
package enum PiSnapshotAccounting: Sendable, Equatable {
    case nativeOnly
    case includesPi(scope: String, native: CostUsageTokenSnapshot)
    case piOnly(scope: String)

    package var scope: String? {
        switch self {
        case .nativeOnly:
            nil
        case let .includesPi(scope, _), let .piOnly(scope):
            scope
        }
    }
}

package struct CostUsageTokenResult: Sendable, Equatable {
    package let snapshot: CostUsageTokenSnapshot
    package let accounting: PiSnapshotAccounting?
    package let antigravityCatchUpPending: Bool
    package let antigravityCatchUpMadeProgress: Bool
    package let antigravityScanActiveDuration: TimeInterval?

    package init(
        snapshot: CostUsageTokenSnapshot,
        accounting: PiSnapshotAccounting? = nil,
        antigravityCatchUpPending: Bool = false,
        antigravityCatchUpMadeProgress: Bool = false)
    {
        self.init(
            snapshot: snapshot,
            accounting: accounting,
            antigravityCatchUpPending: antigravityCatchUpPending,
            antigravityCatchUpMadeProgress: antigravityCatchUpMadeProgress,
            antigravityScanActiveDuration: nil)
    }

    package init(
        snapshot: CostUsageTokenSnapshot,
        accounting: PiSnapshotAccounting? = nil,
        antigravityCatchUpPending: Bool = false,
        antigravityCatchUpMadeProgress: Bool = false,
        antigravityScanActiveDuration: TimeInterval?)
    {
        self.snapshot = snapshot
        self.accounting = accounting
        self.antigravityCatchUpPending = antigravityCatchUpPending
        self.antigravityCatchUpMadeProgress = antigravityCatchUpMadeProgress
        self.antigravityScanActiveDuration = antigravityScanActiveDuration
    }
}
