import Foundation

/// Copilot AI credit consumption for accounts GitHub bills by token/credit rather than by quota.
///
/// These accounts report every quota snapshot as `unlimited` with a zero entitlement, so there is no
/// metered window to render. Credits are the only real usage signal, and GitHub exposes no entitlement
/// on any billing endpoint — the denominator is user-supplied or absent.
public struct CopilotCreditsUsage: Codable, Equatable, Sendable {
    /// One credit-consuming scope: this seat, or the whole organization.
    public struct Lane: Codable, Equatable, Sendable {
        public let creditsUsed: Double
        /// User-supplied monthly allowance. `nil` renders a text row rather than a bar, because GitHub
        /// does not expose the included-credit ceiling on any documented endpoint.
        public let entitlement: Double?
        public let resetsAt: Date?

        public init(creditsUsed: Double, entitlement: Double?, resetsAt: Date?) {
            self.creditsUsed = creditsUsed
            self.entitlement = entitlement
            self.resetsAt = resetsAt
        }

        /// Percent of the allowance consumed, or `nil` when no usable denominator exists.
        ///
        /// Intentionally not clamped: overage-permitted seats can exceed 100%, and `RateWindow`
        /// documents the same convention of leaving provider values un-normalized. Display clamping
        /// belongs to the renderer.
        public var usedPercent: Double? {
            guard let entitlement = self.entitlement, entitlement > 0 else { return nil }
            return (self.creditsUsed / entitlement) * 100
        }
    }

    public let seat: Lane?
    public let org: Lane?
    public let orgLogin: String?

    public init(seat: Lane?, org: Lane?, orgLogin: String?) {
        self.seat = seat
        self.org = org
        self.orgLogin = orgLogin
    }
}

/// Parses the user-entered credit allowance from settings.
///
/// A blank, non-numeric, or non-positive entry means "no denominator" — the card then shows a text row
/// instead of a bar. Never guess a value here; GitHub does not publish the entitlement.
public enum CopilotCreditEntitlementParser {
    public static func parse(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Double(trimmed), value > 0 else { return nil }
        return value
    }
}
