import Foundation

/// A provider-reported plan or tier identifier together with the source that reported it.
///
/// CodexBar records observations, not inferences:
///
/// - `rawPlan` is the provider's own identifier (for example `pro`). It is not a display label
///   ("Pro 20x") and it does not establish an allowance multiplier or baseline.
/// - `observedAt` is when the fetch observed the value, not when the plan took effect. Hooks are
///   sampled, so an observation is not a complete transition history.
/// - `source` names the exact provider surface that reported the identifier.
public struct ProviderPlanObservation: Codable, Equatable, Sendable {
    /// Provider surfaces that can report a raw plan identifier.
    ///
    /// Raw values are stable and appear as `planSource` in `usage_updated` hook payloads.
    public enum Source: String, Codable, Equatable, Sendable {
        /// The provider usage/rate-limit response (`plan_type`).
        case usageResponse = "usage_response"
        /// OAuth ID-token claims (`chatgpt_plan_type`).
        case oauthClaims = "oauth_claims"
        /// The token-auth whoami response (`plan_type`).
        case patWhoami = "pat_whoami"
        /// A local Codex app-server RPC response (rate limits or account details).
        case localRPC = "local_rpc"
    }

    public let rawPlan: String
    public let source: Source
    public let observedAt: Date

    /// Creates an observation only when a source actually reported a non-empty identifier.
    ///
    /// An empty or missing value stays unavailable instead of becoming an empty observation.
    public init?(rawPlan: String?, source: Source, observedAt: Date) {
        guard let trimmed = rawPlan?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        self.rawPlan = trimmed
        self.source = source
        self.observedAt = observedAt
    }
}
