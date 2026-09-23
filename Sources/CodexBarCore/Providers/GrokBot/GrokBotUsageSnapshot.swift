import Foundation

public enum GrokBotProbeError: Error, LocalizedError, Sendable {
    case noAllowance
    case notSupported

    public var errorDescription: String? {
        switch self {
        case .noAllowance:
            "This Cursor account does not have an active Grok Bot allowance or trial."
        case .notSupported:
            "Grok Bot usage is only available on macOS and Linux."
        }
    }
}

public enum GrokBotUsageSnapshot {
    public static func usageSnapshot(
        from sand: CursorSandUsageStatus,
        now: Date = Date()) throws -> UsageSnapshot
    {
        guard let named = sand.extraRateWindow(now: now, resetDescription: Self.formatResetDate) else {
            throw GrokBotProbeError.noAllowance
        }
        return UsageSnapshot(
            primary: named.window,
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: nil)
    }

    private static func formatResetDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d 'at' h:mma"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "Resets " + formatter.string(from: date)
    }
}

#if os(macOS) || os(Linux)
extension CursorStatusProbe {
    public func fetchGrokBotUsage(
        cookieHeaderOverride: String? = nil,
        allowAppAuthFallback: Bool = true,
        logger: ((String) -> Void)? = nil) async throws -> UsageSnapshot
    {
        try await self.resolveSession(
            cookieHeaderOverride: cookieHeaderOverride,
            allowAppAuthFallback: allowAppAuthFallback,
            logger: logger)
        { cookieHeader, _ in
            let (status, _) = try await self.fetchSandUsage(cookieHeader: cookieHeader, deadline: nil)
            return try GrokBotUsageSnapshot.usageSnapshot(from: status)
        }
    }
}
#endif
