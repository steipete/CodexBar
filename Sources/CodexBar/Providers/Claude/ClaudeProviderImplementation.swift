import CodexBarCore
import Foundation

struct ClaudeUsageStrategy: Equatable, Sendable {
    let dataSource: ClaudeUsageDataSource
    let useWebExtras: Bool
    let isZaiConfigured: Bool
}

struct ClaudeProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .claude
    let style: IconStyle = .claude

    @MainActor
    func settingsToggles(context: ProviderSettingsContext) -> [ProviderSettingsToggleDescriptor] {
        let id = "claude.webExtras"

        let statusText: () -> String? = { context.statusText(id) }

        let toggle = ProviderSettingsToggleDescriptor(
            id: id,
            title: "Augment Claude via web",
            subtitle: [
                "Uses Safari/Chrome/Firefox session cookies to add extra dashboard fields on top of OAuth.",
                "Adds Extra usage spend/limit.",
                "Safari → Chrome → Firefox.",
            ].joined(separator: " "),
            binding: context.boolBinding(\.claudeWebExtrasEnabled),
            statusText: statusText,
            actions: [],
            isVisible: { context.settings.claudeUsageDataSource == .cli },
            onChange: { enabled in
                if !enabled {
                    context.setStatusText(id, nil)
                }
            },
            onAppDidBecomeActive: nil,
            onAppearWhenEnabled: {
                await Self.refreshWebExtrasStatus(context: context, id: id)
            })

        return [toggle]
    }

    @MainActor
    static func usageStrategy(
        settings: SettingsStore,
        hasWebSession: () -> Bool = { ClaudeWebAPIFetcher.hasSessionKey() }) -> ClaudeUsageStrategy
    {
        // Check if z.ai is configured first
        let claudeSettings = ClaudeSettingsReader.readSettings()
        let isZaiConfigured = claudeSettings.isZaiConfigured

        if isZaiConfigured {
            // When z.ai is configured, we use a special data source that bypasses CLI/cookies
            return ClaudeUsageStrategy(dataSource: .oauth, useWebExtras: false, isZaiConfigured: true)
        }

        if settings.debugMenuEnabled {
            let dataSource = settings.claudeUsageDataSource
            if dataSource == .oauth {
                return ClaudeUsageStrategy(dataSource: dataSource, useWebExtras: false, isZaiConfigured: false)
            }
            let hasSession = hasWebSession()
            if dataSource == .web, !hasSession {
                return ClaudeUsageStrategy(dataSource: .cli, useWebExtras: false, isZaiConfigured: false)
            }
            let useWebExtras = dataSource == .cli && settings.claudeWebExtrasEnabled && hasSession
            return ClaudeUsageStrategy(dataSource: dataSource, useWebExtras: useWebExtras, isZaiConfigured: false)
        }

        let hasSession = hasWebSession()
        let dataSource: ClaudeUsageDataSource = hasSession ? .web : .cli
        return ClaudeUsageStrategy(dataSource: dataSource, useWebExtras: false, isZaiConfigured: false)
    }

    func makeFetch(context: ProviderBuildContext) -> @Sendable () async throws -> UsageSnapshot {
        {
            let strategy = await MainActor.run { Self.usageStrategy(settings: context.settings) }

            // When z.ai is configured, use the z.ai-only fetcher
            if strategy.isZaiConfigured {
                return try await Self.fetchZaiUsage()
            }

            let fetcher: any ClaudeUsageFetching = if context.claudeFetcher is ClaudeUsageFetcher {
                ClaudeUsageFetcher(dataSource: strategy.dataSource, useWebExtras: strategy.useWebExtras)
            } else {
                context.claudeFetcher
            }

            let usage = try await fetcher.loadLatestUsage(model: "sonnet")
            return UsageSnapshot(
                primary: usage.primary,
                secondary: usage.secondary,
                tertiary: usage.opus,
                providerCost: usage.providerCost,
                zaiUsage: usage.zaiUsage,
                updatedAt: usage.updatedAt,
                accountEmail: usage.accountEmail,
                accountOrganization: usage.accountOrganization,
                loginMethod: usage.loginMethod)
        }
    }

    // MARK: - z.ai usage fetching

    private static func fetchZaiUsage() async throws -> UsageSnapshot {
        let settings = ClaudeSettingsReader.readSettings()
        guard settings.isZaiConfigured, let apiKey = settings.apiToken else {
            throw ClaudeUsageError.parseFailed("z.ai configured but no API key found")
        }

        let zaiUsage = try await ZaiUsageFetcher.fetchUsage(apiKey: apiKey)
        return zaiUsage.toUsageSnapshot()
    }

    // MARK: - Web extras status

    @MainActor
    private static func refreshWebExtrasStatus(context: ProviderSettingsContext, id: String) async {
        let expectedEmail = context.store.snapshot(for: .claude)?.accountEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        context.setStatusText(id, "Checking Claude cookies…")
        let status = await Self.loadClaudeWebStatus(expectedEmail: expectedEmail)
        context.setStatusText(id, status)
    }

    private static func loadClaudeWebStatus(expectedEmail: String?) async -> String {
        await Task.detached(priority: .utility) {
            do {
                let info = try ClaudeWebAPIFetcher.sessionKeyInfo()
                var parts = ["Using \(info.sourceLabel) cookies (\(info.cookieCount))."]

                do {
                    let usage = try await ClaudeWebAPIFetcher.fetchUsage(using: info)
                    if let rawEmail = usage.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !rawEmail.isEmpty
                    {
                        if let expectedEmail, !expectedEmail.isEmpty {
                            let matches = rawEmail.lowercased() == expectedEmail.lowercased()
                            let matchText = matches ? "matches Claude" : "does not match Claude"
                            parts.append("Signed in as \(rawEmail) (\(matchText)).")
                        } else {
                            parts.append("Signed in as \(rawEmail).")
                        }
                    }
                } catch {
                    parts.append("Signed-in status unavailable: \(error.localizedDescription)")
                }

                return parts.joined(separator: " ")
            } catch {
                return "Browser cookie import failed: \(error.localizedDescription)"
            }
        }.value
    }
}
