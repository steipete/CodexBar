import Foundation

#if DEBUG
extension UsageFetcher {
    static func _mapCodexRPCLimitsForTesting(
        primary: (usedPercent: Double, windowMinutes: Int, resetsAt: Int?)?,
        secondary: (usedPercent: Double, windowMinutes: Int, resetsAt: Int?)?,
        planType: String? = nil) throws -> UsageSnapshot
    {
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: self.normalizedCodexAccountField(planType))
        guard let state = CodexReconciledState.fromCLI(
            primary: primary.map(self.makeTestingWindow),
            secondary: secondary.map(self.makeTestingWindow),
            identity: identity)
        else {
            if let usage = self.emptyCodexUsageSnapshotIfIdentified(identity: identity) {
                return usage
            }
            throw UsageError.noRateLimitsFound
        }
        return state.toUsageSnapshot()
    }

    static func _mapCodexStatusForTesting(_ status: CodexStatusSnapshot) throws -> UsageSnapshot {
        guard let state = CodexReconciledState.fromCLI(
            primary: self.makeTTYWindow(
                percentLeft: status.fiveHourPercentLeft,
                windowMinutes: 300,
                resetsAt: status.fiveHourResetsAt,
                resetDescription: status.fiveHourResetDescription),
            secondary: self.makeTTYWindow(
                percentLeft: status.weeklyPercentLeft,
                windowMinutes: 10080,
                resetsAt: status.weeklyResetsAt,
                resetDescription: status.weeklyResetDescription),
            identity: nil)
        else {
            throw UsageError.noRateLimitsFound
        }
        return state.toUsageSnapshot()
    }

    public static func _recoverCodexRPCUsageFromErrorForTesting(_ message: String) -> UsageSnapshot? {
        self.recoverUsageFromRPCError(RPCWireError.requestFailed(message))
    }

    public static func _recoverCodexRPCCreditsFromErrorForTesting(_ message: String) -> CreditsSnapshot? {
        self.recoverCreditsFromRPCError(RPCWireError.requestFailed(message))
    }

    private static func makeTestingWindow(
        _ value: (usedPercent: Double, windowMinutes: Int, resetsAt: Int?))
        -> RateWindow
    {
        let resetsAt = value.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return RateWindow(
            usedPercent: value.usedPercent,
            windowMinutes: value.windowMinutes,
            resetsAt: resetsAt,
            resetDescription: resetsAt.map { UsageFormatter.resetDescription(from: $0) })
    }
}
#endif
