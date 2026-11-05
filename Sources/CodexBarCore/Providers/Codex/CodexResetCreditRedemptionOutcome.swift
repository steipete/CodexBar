import Foundation

public enum CodexResetCreditRedemptionOutcome: String, Decodable, Sendable {
    case reset
    case alreadyRedeemed = "already_redeemed"
    case nothingToReset = "nothing_to_reset"
    case noCredit = "no_credit"
    /// The fresh inventory no longer contains the selected eligible expiring credit.
    case unavailable
}
