import CodexBarCore
import Foundation

/// A single account's usage snapshot, used in the Costs summary card.
struct AccountCostEntry: Identifiable, Sendable {
    let id: String // "default" or account UUID string
    let label: String
    let isDefault: Bool
    /// Prepaid credits balance (nil when on a subscription plan or not available).
    let creditsRemaining: Double?
    let isUnlimited: Bool
    /// Plan name, e.g. "Pro", "Team", "Free".
    let planType: String?
    /// Primary (session) rate-window usage percent (0-100).
    let primaryUsedPercent: Double?
    /// Secondary (weekly) rate-window usage percent (0-100). Preferred for display.
    let secondaryUsedPercent: Double?
    /// Compact countdown reset time for the session window, e.g. "in 3h 31m".
    let primaryResetDescription: String?
    /// Compact countdown reset time for the weekly window, e.g. "in 1d 2h".
    let secondaryResetDescription: String?
    let error: String?
    let updatedAt: Date
}

extension UsageStore {
    /// Fetches the credits balance for every Codex account (default + all token accounts)
    /// concurrently via the OAuth API and stores results in `allAccountCredits[provider]`.
    func refreshAllAccountCredits(for provider: UsageProvider) async {
        guard provider == .codex else { return }
        guard !self.accountCostRefreshInFlight.contains(provider) else { return }
        self.accountCostRefreshInFlight.insert(provider)
        defer { self.accountCostRefreshInFlight.remove(provider) }

        let tokenAccounts = self.settings.tokenAccounts(for: provider)
        let defaultLabel = ProviderCatalog.implementation(for: provider)?
            .tokenAccountDefaultLabel(settings: self.settings) ?? "Default"

        // Fetch all accounts in parallel.
        var entries: [AccountCostEntry] = await withTaskGroup(
            of: (index: Int, entry: AccountCostEntry).self,
            returning: [AccountCostEntry].self)
        { group in
            // Default account (index 0)
            group.addTask {
                let entry = await Self.fetchCredits(
                    env: [:],
                    id: "default",
                    label: defaultLabel,
                    isDefault: true)
                return (0, entry)
            }
            // Token accounts (index 1…)
            for (offset, account) in tokenAccounts.enumerated() {
                group.addTask {
                    guard let env = TokenAccountSupportCatalog.envOverride(for: .codex, token: account.token) else {
                        let entry = AccountCostEntry(
                            id: account.id.uuidString,
                            label: account.label,
                            isDefault: false,
                            creditsRemaining: nil,
                            isUnlimited: false,
                            planType: nil,
                            primaryUsedPercent: nil,
                            secondaryUsedPercent: nil,
                            primaryResetDescription: nil,
                            secondaryResetDescription: nil,
                            error: "Invalid Codex account token",
                            updatedAt: Date())
                        return (offset + 1, entry)
                    }
                    let entry = await Self.fetchCredits(
                        env: env,
                        id: account.id.uuidString,
                        label: account.label,
                        isDefault: false)
                    return (offset + 1, entry)
                }
            }

            var results: [(Int, AccountCostEntry)] = []
            for await pair in group {
                results.append(pair)
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }

        // Only keep accounts that returned something useful (or an error worth surfacing).
        // Drop the default entry entirely if there's no auth.json (not logged in at all).
        entries = entries.filter { entry in
            if entry.isDefault, entry.creditsRemaining == nil, entry.error?.contains("not found") == true {
                return false
            }
            return true
        }

        await MainActor.run {
            self.allAccountCredits[provider] = entries
        }
    }

    private static func fetchCredits(
        env: [String: String],
        id: String,
        label: String,
        isDefault: Bool) async -> AccountCostEntry
    {
        do {
            var credentials = try CodexOAuthCredentialsStore.load(env: env)
            if credentials.needsRefresh, !credentials.refreshToken.isEmpty {
                if let refreshed = try? await CodexTokenRefresher.refresh(credentials) {
                    try? CodexOAuthCredentialsStore.save(refreshed, env: env)
                    credentials = refreshed
                }
            }
            let response = try await CodexOAuthUsageFetcher.fetchUsage(
                accessToken: credentials.accessToken,
                accountId: credentials.accountId)

            // Credits balance: only meaningful when > 0 (subscription plans return 0).
            let rawBalance = response.credits?.balance
            let balance: Double? = (rawBalance ?? 0) > 0 ? rawBalance : nil
            let unlimited = response.credits?.unlimited ?? false

            // Plan type display name.
            let planType = response.planType.map { Self.planDisplayName($0) }

            // Rate-window usage — prefer weekly (secondary) for display, keep primary as fallback.
            let primaryWindow = response.rateLimit?.primaryWindow
            let secondaryWindow = response.rateLimit?.secondaryWindow
            let primaryUsedPercent = primaryWindow.map { Double($0.usedPercent) }
            let secondaryUsedPercent = secondaryWindow.map { Double($0.usedPercent) }
            let primaryResetDesc: String? = primaryWindow.map {
                let date = Date(timeIntervalSince1970: TimeInterval($0.resetAt))
                let s = UsageFormatter.resetCountdownDescription(from: date)
                return s.hasPrefix("in ") ? String(s.dropFirst(3)) : s
            }
            let secondaryResetDesc: String? = secondaryWindow.map {
                let date = Date(timeIntervalSince1970: TimeInterval($0.resetAt))
                let s = UsageFormatter.resetCountdownDescription(from: date)
                return s.hasPrefix("in ") ? String(s.dropFirst(3)) : s
            }

            return AccountCostEntry(
                id: id,
                label: label,
                isDefault: isDefault,
                creditsRemaining: balance,
                isUnlimited: unlimited,
                planType: planType,
                primaryUsedPercent: primaryUsedPercent,
                secondaryUsedPercent: secondaryUsedPercent,
                primaryResetDescription: primaryResetDesc,
                secondaryResetDescription: secondaryResetDesc,
                error: nil,
                updatedAt: Date())
        } catch {
            return AccountCostEntry(
                id: id,
                label: label,
                isDefault: isDefault,
                creditsRemaining: nil,
                isUnlimited: false,
                planType: nil,
                primaryUsedPercent: nil,
                secondaryUsedPercent: nil,
                primaryResetDescription: nil,
                secondaryResetDescription: nil,
                error: error.localizedDescription,
                updatedAt: Date())
        }
    }

    private static func planDisplayName(_ plan: CodexUsageResponse.PlanType) -> String {
        switch plan {
        case .guest: "Guest"
        case .free: "Free"
        case .go: "Go"
        case .plus: "Plus"
        case .pro: "Pro"
        case .freeWorkspace: "Free Workspace"
        case .team: "Team"
        case .business: "Business"
        case .education: "Education"
        case .quorum: "Quorum"
        case .k12: "K-12"
        case .enterprise: "Enterprise"
        case .edu: "Edu"
        case let .unknown(raw): raw.capitalized
        }
    }
}
