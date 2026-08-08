import Foundation

/// Parses the user-entered credit allowance from settings.
///
/// A blank, non-numeric, or non-positive entry means "no denominator" — the card then shows a text row
/// instead of a bar. Never guess a value here; GitHub does not publish the entitlement.
public enum CopilotCreditEntitlementParser {
    public static func parse(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // `isFinite` matters: "inf"/"1e999" parse to .infinity, which would crash the progress
        // validation downstream.
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite, value > 0 else { return nil }
        return value
    }
}
