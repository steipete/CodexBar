import Foundation

/// Fetches Antigravity usage for the `agy` CLI session.
///
/// Established usage sources for `agy` (no top-level `account status` subcommand):
/// 1. **Interactive `/usage` panel** — PTY capture of the agy TUI slash command. Matches the
///    "Model Quota" view (Claude + Gemini + other model buckets).
/// 2. **Antigravity remote API** — `fetchAvailableModels` OAuth from `~/.gemini/oauth_creds.json`.
/// 3. **Gemini quota API** — `retrieveUserQuota` via `GeminiStatusProbe` (Gemini buckets only).
public enum AntigravityAgyStatusProbe: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.antigravity)

    public static func fetch(
        timeout: TimeInterval = 10.0,
        homeDirectory: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws
        -> AntigravityStatusSnapshot
    {
        guard AntigravityAgyCredentials.isCLIInstalled(env: environment)
            || AntigravityAgyCredentials.hasStoredCredentials(homeDirectory: homeDirectory)
        else {
            throw AntigravityRemoteFetchError.notLoggedIn
        }

        var cliSnapshot: AntigravityStatusSnapshot?
        var remoteSnapshot: AntigravityStatusSnapshot?
        var geminiSnapshot: AntigravityStatusSnapshot?
        var lastError: Error?

        // 1. Preferred: agy interactive `/usage` panel (Claude + Gemini when logged in).
        if AntigravityAgyCredentials.isCLIInstalled(env: environment) {
            do {
                let snapshot = try await AntigravityAgyCLIUsageProbe.fetch(
                    timeout: max(timeout, 18),
                    env: environment)
                if !snapshot.modelQuotas.isEmpty {
                    cliSnapshot = snapshot
                    Self.log.info(
                        "Antigravity agy /usage fetch ok",
                        metadata: ["modelCount": "\(snapshot.modelQuotas.count)"])
                }
            } catch {
                lastError = error
                Self.log.debug("Antigravity agy /usage fetch failed: \(error.localizedDescription)")
            }
        }

        if let cliSnapshot, Self.isUsableCLISnapshot(cliSnapshot) {
            return Self.enrichAccountMetadata(cliSnapshot, homeDirectory: homeDirectory)
        }

        let skipRemoteAPI = cliSnapshot.map { Self.isUsableCLISnapshot($0) } ?? false

        // 2. Antigravity remote API (Claude + Gemini when permitted).
        if !skipRemoteAPI {
            do {
                let fetcher = AntigravityRemoteUsageFetcher(
                    timeout: timeout,
                    homeDirectory: homeDirectory,
                    environment: environment,
                    credentialPreference: .agyCLI)
                let snapshot = try await fetcher.fetch()
                if !snapshot.modelQuotas.isEmpty {
                    remoteSnapshot = snapshot
                    Self.log.info(
                        "Antigravity agy remote fetch ok",
                        metadata: ["modelCount": "\(snapshot.modelQuotas.count)"])
                }
            } catch {
                lastError = error
                Self.log.debug("Antigravity agy remote fetch failed: \(error.localizedDescription)")
            }
        }

        // 3. Fallback: Gemini quota API (same OAuth session, fast and reliable for Gemini buckets).
        do {
            let geminiProbe = GeminiStatusProbe(timeout: timeout, homeDirectory: homeDirectory)
            let gemini = try await geminiProbe.fetch()
            geminiSnapshot = Self.makeAntigravitySnapshot(from: gemini)
            Self.log.info(
                "Antigravity agy gemini quota fetch ok",
                metadata: ["modelCount": "\(geminiSnapshot?.modelQuotas.count ?? 0)"])
        } catch {
            if lastError == nil { lastError = error }
            Self.log.debug("Antigravity agy gemini quota fetch failed: \(error.localizedDescription)")
        }

        let merged = Self.mergeSnapshots(
            cli: cliSnapshot,
            remote: remoteSnapshot,
            gemini: geminiSnapshot)

        guard !merged.modelQuotas.isEmpty else {
            Self.log.warning("Antigravity agy usage fetch returned no model quotas")
            throw lastError ?? AntigravityRemoteFetchError.parseFailed("No quota models available")
        }

        return merged
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

    static func mergeSnapshots(
        cli: AntigravityStatusSnapshot? = nil,
        remote: AntigravityStatusSnapshot?,
        gemini: AntigravityStatusSnapshot?) -> AntigravityStatusSnapshot
    {
        var quotasByKey: [String: AntigravityModelQuota] = [:]

        if let gemini {
            for quota in gemini.modelQuotas {
                quotasByKey[Self.quotaKey(quota)] = quota
            }
        }

        if let remote {
            for quota in remote.modelQuotas {
                quotasByKey[Self.quotaKey(quota)] = quota
            }
        }

        if let cli {
            for quota in cli.modelQuotas {
                quotasByKey[Self.quotaKey(quota)] = quota
            }
        }

        let modelQuotas = quotasByKey.values.sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }

        let accountEmail = cli?.accountEmail ?? remote?.accountEmail ?? gemini?.accountEmail
        let accountPlan = Self.meaningfulAccountPlan(cli?.accountPlan)
            ?? Self.meaningfulAccountPlan(remote?.accountPlan)
            ?? Self.meaningfulAccountPlan(gemini?.accountPlan)

        return AntigravityStatusSnapshot(
            modelQuotas: modelQuotas,
            accountEmail: accountEmail,
            accountPlan: accountPlan)
    }

    private static func isUsableCLISnapshot(_ snapshot: AntigravityStatusSnapshot) -> Bool {
        guard !snapshot.modelQuotas.isEmpty else { return false }
        let families = snapshot.modelQuotas.map { quota in
            let haystack = "\(quota.label) \(quota.modelId)".lowercased()
            if haystack.contains("claude") { return "claude" }
            if haystack.contains("gemini"), haystack.contains("pro") { return "gemini-pro" }
            if haystack.contains("gemini"), haystack.contains("flash") { return "gemini-flash" }
            return "other"
        }
        let uniqueFamilies = Set(families)
        return uniqueFamilies.contains("claude")
            && (uniqueFamilies.contains("gemini-pro") || uniqueFamilies.contains("gemini-flash"))
    }

    private static func enrichAccountMetadata(
        _ snapshot: AntigravityStatusSnapshot,
        homeDirectory: String) -> AntigravityStatusSnapshot
    {
        guard snapshot.accountEmail == nil || snapshot.accountPlan == nil else {
            return snapshot
        }

        guard snapshot.accountEmail == nil else { return snapshot }
        guard let credentials = try? AntigravityAgyCredentials.loadCredentials(homeDirectory: homeDirectory),
              let email = credentials.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty
        else {
            return snapshot
        }

        return AntigravityStatusSnapshot(
            modelQuotas: snapshot.modelQuotas,
            accountEmail: email,
            accountPlan: snapshot.accountPlan)
    }

    /// The Antigravity CLI (`agy`) reaches Gemini quota through Google's free Code Assist
    /// individual tier, so the remote/Gemini plan lookup reports "Free" even for accounts with a
    /// paid Antigravity subscription. That label describes the Gemini lane, not the Antigravity
    /// account, and `agy` exposes no authoritative account plan, so we drop a bare "Free" rather
    /// than mislabel a paid account. Any concrete plan (Paid/Workspace/Legacy/etc.) passes through.
    private static func meaningfulAccountPlan(_ plan: String?) -> String? {
        guard let plan = plan?.trimmingCharacters(in: .whitespacesAndNewlines), !plan.isEmpty else {
            return nil
        }
        if plan.caseInsensitiveCompare("Free") == .orderedSame {
            return nil
        }
        return plan
    }

    private static func quotaKey(_ quota: AntigravityModelQuota) -> String {
        quota.modelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
