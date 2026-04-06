import CodexBarCore
import CryptoKit
import Foundation

struct CodexOwnershipContext: Sendable {
    let canonicalKey: String?
    let canonicalEmailHashKey: String?
    let historicalLegacyEmailHash: String?
    let planUtilizationLegacyEmailHash: String?
    let currentWeeklyResetAt: Date?
    let hasAdjacentMultiAccountVeto: Bool
}

extension UsageStore {
    func codexOwnershipContext(
        preferredEmail: String? = nil,
        snapshot: UsageSnapshot? = nil,
        includeDashboardFallback: Bool = false) -> CodexOwnershipContext
    {
        let resolvedIdentity = self.currentCodexRuntimeIdentity(
            source: self.settings.codexResolvedActiveSource,
            preferCurrentSnapshot: true,
            allowLastKnownLiveFallback: true)
        let activeSourceEmail = self.codexAccountScopedRefreshEmail(
            preferCurrentSnapshot: true,
            allowLastKnownLiveFallback: true)
        let normalizedEmail = CodexIdentityResolver.normalizeEmail(
            preferredEmail ??
                activeSourceEmail ??
                snapshot?.accountEmail(for: .codex) ??
                self.snapshots[.codex]?.accountEmail(for: .codex) ??
                (includeDashboardFallback ? self.codexAccountEmailForOpenAIDashboard() : nil))
        let canonicalIdentity: CodexIdentity = switch resolvedIdentity {
        case .unresolved:
            if let normalizedEmail {
                .emailOnly(normalizedEmail: normalizedEmail)
            } else {
                .unresolved
            }
        default:
            resolvedIdentity
        }
        let legacyEmailSource: String? = switch canonicalIdentity {
        case let .emailOnly(normalizedEmail):
            normalizedEmail
        case .providerAccount, .unresolved:
            normalizedEmail
        }
        let attachedDashboardSnapshot = includeDashboardFallback
            ? self.attachedOpenAIDashboardSnapshot
            : nil
        let normalizedDashboardSnapshot = attachedDashboardSnapshot?
            .toUsageSnapshot(provider: .codex, accountEmail: normalizedEmail)
        let currentWeeklyResetAt = snapshot?.secondary?.resetsAt
            ?? self.snapshots[.codex]?.secondary?.resetsAt
            ?? normalizedDashboardSnapshot?.secondary?.resetsAt

        return CodexOwnershipContext(
            canonicalKey: CodexHistoryOwnership.canonicalKey(for: canonicalIdentity),
            canonicalEmailHashKey: normalizedEmail.map { CodexHistoryOwnership.canonicalEmailHashKey(for: $0) },
            historicalLegacyEmailHash: legacyEmailSource.map {
                CodexHistoryOwnership.legacyEmailHash(normalizedEmail: $0)
            },
            planUtilizationLegacyEmailHash: legacyEmailSource.map {
                Self.codexLegacyPlanUtilizationEmailHashKey(for: $0)
            },
            currentWeeklyResetAt: currentWeeklyResetAt,
            hasAdjacentMultiAccountVeto: self.codexHasAdjacentMultiAccountVeto())
    }

    func codexHasAdjacentMultiAccountVeto() -> Bool {
        let snapshot = self.settings.codexAccountReconciliationSnapshot
        var distinctAccounts: Set<String> = []

        if let activeManagedAccount = self.settings.activeManagedCodexAccount {
            distinctAccounts.insert(CodexIdentityMatcher.selectionKey(
                for: snapshot.runtimeIdentity(for: activeManagedAccount),
                fallbackEmail: snapshot.runtimeEmail(for: activeManagedAccount)))
        }

        if let liveSystemAccount = snapshot.liveSystemAccount {
            distinctAccounts.insert(CodexIdentityMatcher.selectionKey(
                for: snapshot.runtimeIdentity(for: liveSystemAccount),
                fallbackEmail: liveSystemAccount.email))
        }

        return distinctAccounts.count > 1
    }

    nonisolated static func codexLegacyPlanUtilizationEmailHashKey(for normalizedEmail: String) -> String {
        self.sha256Hex("\(UsageProvider.codex.rawValue):email:\(normalizedEmail)")
    }

    nonisolated static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
