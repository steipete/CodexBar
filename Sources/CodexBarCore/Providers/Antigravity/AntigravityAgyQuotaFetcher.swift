import Foundation

/// Fetches Antigravity usage quotas from the Antigravity CLI (`agy`) OAuth session.
///
/// The `agy` binary does not expose an `account status` command like `auggie`. It stores OAuth
/// at `~/.gemini/oauth_creds.json`, and the reliable quota endpoint for that session is the same
/// Gemini Code Assist `retrieveUserQuota` API used by the Gemini provider.
enum AntigravityAgyQuotaFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.antigravity)

    static func fetch(timeout: TimeInterval = 10.0) async throws -> AntigravityStatusSnapshot {
        guard AntigravityAgyCredentials.isAvailable() else {
            throw AntigravityRemoteFetchError.notLoggedIn
        }

        let geminiProbe = GeminiStatusProbe(timeout: timeout)
        let geminiSnapshot = try await geminiProbe.fetch()
        let snapshot = Self.makeAntigravitySnapshot(from: geminiSnapshot)

        guard !snapshot.modelQuotas.isEmpty else {
            Self.log.warning("Antigravity agy quota fetch returned no model quotas")
            throw AntigravityRemoteFetchError.parseFailed("No quota models available")
        }

        Self.log.info(
            "Antigravity agy quota fetch ok",
            metadata: ["modelCount": "\(snapshot.modelQuotas.count)"])
        return snapshot
    }

    static func makeAntigravitySnapshot(from geminiSnapshot: GeminiStatusSnapshot) -> AntigravityStatusSnapshot {
        let modelQuotas = geminiSnapshot.modelQuotas.map { quota in
            AntigravityModelQuota(
                label: quota.modelId,
                modelId: quota.modelId,
                remainingFraction: quota.percentLeft / 100.0,
                resetTime: quota.resetTime,
                resetDescription: quota.resetDescription)
        }

        return AntigravityStatusSnapshot(
            modelQuotas: modelQuotas,
            accountEmail: geminiSnapshot.accountEmail,
            accountPlan: geminiSnapshot.accountPlan)
    }
}
