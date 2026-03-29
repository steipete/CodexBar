import CodexBariOSShared
import Foundation
import Observation
import WidgetKit

@MainActor
@Observable
final class DashboardModel {
    static let automaticRefreshInterval: TimeInterval = 15 * 60

    struct ClaudeLoginSession: Identifiable {
        let id = UUID()
        let entryURL: URL
    }

    var codexAccessToken = ""
    var codexAccountID = ""
    var claudeAccessToken = ""
    var hasClaudeWebSession = false
    var snapshot: WidgetSnapshot?
    var widgetRefreshDiagnostics: WidgetRefreshDiagnostics?
    var refreshErrors: [UsageProvider: String] = [:]
    var isRefreshing = false
    var activeBrowserLoginProvider: UsageProvider?
    var statusMessage: String?
    var claudeLoginSession: ClaudeLoginSession?

    private let refreshService = UsageRefreshService()
    private let browserLoginCoordinator = BrowserLoginCoordinator()
    private var shouldRefreshOnNextActivation = true
    init() {
        self.loadState()
    }

    func entry(for provider: UsageProvider) -> WidgetSnapshot.ProviderEntry? {
        self.snapshot?.entries.first { $0.provider == provider }
    }

    func error(for provider: UsageProvider) -> String? {
        self.refreshErrors[provider]
    }

    func save(provider: UsageProvider) {
        do {
            switch provider {
            case .codex:
                if self.codexAccessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try CredentialsStore.deleteCodex()
                } else {
                    try CredentialsStore.saveCodex(.init(
                        accessToken: self.codexAccessToken.trimmingCharacters(in: .whitespacesAndNewlines),
                        accountID: self.codexAccountID.nilIfBlank))
                }
            case .claude:
                if self.claudeAccessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try CredentialsStore.deleteClaude()
                } else {
                    try CredentialsStore.deleteClaudeWebSession()
                    try CredentialsStore.saveClaude(.init(
                        accessToken: self.claudeAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)))
                    self.hasClaudeWebSession = false
                }
            }
            self.statusMessage = "\(provider.displayName) credentials saved."
        } catch {
            self.statusMessage = error.localizedDescription
        }
    }

    func clear(provider: UsageProvider) {
        do {
            switch provider {
            case .codex:
                try CredentialsStore.deleteCodex()
                self.codexAccessToken = ""
                self.codexAccountID = ""
            case .claude:
                try CredentialsStore.deleteClaude()
                try CredentialsStore.deleteClaudeWebSession()
                self.claudeAccessToken = ""
                self.hasClaudeWebSession = false
            }
            self.refreshErrors[provider] = nil
            self.snapshot = WidgetSnapshotStore.load()
            self.statusMessage = "\(provider.displayName) credentials cleared."
        } catch {
            self.statusMessage = error.localizedDescription
        }
    }

    func refreshAll(silent: Bool = false) async {
        guard !self.isRefreshing else { return }
        self.isRefreshing = true
        if !silent {
            self.statusMessage = "Refreshing usage…"
        }
        let outcome = await self.refreshService.refreshAll()
        self.snapshot = outcome.snapshot
        self.refreshErrors = outcome.errors
        self.isRefreshing = false
        WidgetCenter.shared.reloadAllTimelines()
        if !silent {
            if outcome.snapshot.entries.isEmpty {
                self.statusMessage = "Add Codex or Claude credentials to populate the widget."
            } else if outcome.errors.isEmpty {
                self.statusMessage = "Widget snapshot updated."
            } else {
                self.statusMessage = "Refresh completed with errors."
            }
        }
    }

    func activateAutomaticRefresh() async {
        self.widgetRefreshDiagnostics = WidgetRefreshDiagnosticsStore.load()
        guard self.shouldRefreshOnNextActivation else { return }
        self.shouldRefreshOnNextActivation = false
        await self.refreshIfNeeded(force: true)
        self.widgetRefreshDiagnostics = WidgetRefreshDiagnosticsStore.load()
    }

    func prepareForNextActivationRefresh() {
        self.shouldRefreshOnNextActivation = true
    }

    func performBackgroundRefresh() async {
        guard self.hasConfiguredCredentials else { return }
        await self.refreshIfNeeded(force: true)
    }

    func browserLogin(provider: UsageProvider) async {
        guard self.activeBrowserLoginProvider == nil else { return }

        do {
            switch provider {
            case .codex:
                self.activeBrowserLoginProvider = provider
                self.statusMessage = "Opening \(provider.displayName) login…"
                defer {
                    self.activeBrowserLoginProvider = nil
                }
                let credentials = try await self.browserLoginCoordinator.loginCodex()
                try CredentialsStore.saveCodex(credentials)
                self.codexAccessToken = credentials.accessToken
                self.codexAccountID = credentials.accountID ?? ""
            case .claude:
                self.beginClaudeBrowserLogin()
                return
            }

            await self.refreshAll()
            if let error = self.refreshErrors[provider] {
                self.statusMessage = "\(provider.displayName) signed in, but refresh failed: \(error)"
            } else {
                self.statusMessage = "\(provider.displayName) signed in and widget refreshed."
            }
        } catch {
            self.statusMessage = error.localizedDescription
        }
    }

    func beginClaudeBrowserLogin() {
        guard self.activeBrowserLoginProvider == nil else { return }
        self.activeBrowserLoginProvider = .claude
        self.refreshErrors[.claude] = nil
        self.statusMessage = "Open Claude in the full-screen browser and finish sign-in. The app will save the web session automatically."
        self.claudeLoginSession = ClaudeLoginSession(entryURL: URL(string: "https://claude.ai/settings/usage")!)
    }

    func completeClaudeBrowserLogin(_ result: Result<ClaudeWebSession, Error>) async {
        defer {
            self.claudeLoginSession = nil
            self.activeBrowserLoginProvider = nil
        }

        do {
            let session = try result.get()
            try CredentialsStore.deleteClaude()
            try CredentialsStore.saveClaudeWebSession(session)
            self.claudeAccessToken = ""
            self.hasClaudeWebSession = true

            await self.refreshAll()
            if let error = self.refreshErrors[.claude] {
                self.statusMessage = "Claude web session saved, but refresh failed: \(error)"
            } else {
                self.statusMessage = "Claude web session saved and widget refreshed."
            }
        } catch {
            self.statusMessage = error.localizedDescription
        }
    }

    func cancelClaudeBrowserLogin() {
        guard self.claudeLoginSession != nil else { return }
        self.claudeLoginSession = nil
        self.activeBrowserLoginProvider = nil
        self.statusMessage = "Claude login cancelled."
    }

    func browserLoginSupported(provider: UsageProvider) -> Bool {
        switch provider {
        case .codex:
            return true
        case .claude:
            return true
        }
    }

    func isAuthenticating(provider: UsageProvider) -> Bool {
        self.activeBrowserLoginProvider == provider
    }

    func browserLoginHint(provider: UsageProvider) -> String? {
        switch provider {
        case .codex:
            return "Open the Codex login page in a browser sheet and capture OAuth credentials automatically using the CLI-compatible localhost callback."
        case .claude:
            return "Open `claude.ai` in a full-screen in-app browser, complete sign-in, and capture the Claude web session cookie automatically."
        }
    }

    func storedCredentialLabel(provider: UsageProvider) -> String? {
        switch provider {
        case .codex:
            return self.codexAccessToken.nilIfBlank == nil ? nil : "OAuth ready"
        case .claude:
            if self.hasClaudeWebSession {
                return "Web session ready"
            }
            return self.claudeAccessToken.nilIfBlank == nil ? nil : "Token ready"
        }
    }

    func loadState() {
        if let codex = try? CredentialsStore.loadCodex() {
            self.codexAccessToken = codex.accessToken
            self.codexAccountID = codex.accountID ?? ""
        }
        if let claude = try? CredentialsStore.loadClaude() {
            self.claudeAccessToken = claude.accessToken
        }
        self.hasClaudeWebSession = (try? CredentialsStore.loadClaudeWebSession())?.isValid == true
        self.snapshot = WidgetSnapshotStore.load()
        self.widgetRefreshDiagnostics = WidgetRefreshDiagnosticsStore.load()
    }

    var widgetRefreshSummary: String {
        guard let widgetRefreshDiagnostics else { return "none" }
        let status: String = switch widgetRefreshDiagnostics.result {
        case .refreshed: "ok"
        case .cached: "cached"
        case .skipped: "skip"
        }
        return "#\(widgetRefreshDiagnostics.requestCount) \(status)"
    }

    var widgetRefreshDetail: String? {
        guard let widgetRefreshDiagnostics else { return nil }
        let source = widgetRefreshDiagnostics.source?.displayName ?? "unknown"
        let network = widgetRefreshDiagnostics.networkAttempted ? "network" : "no-network"
        return "Timeline #\(widgetRefreshDiagnostics.requestCount) | \(DisplayFormat.updateTimestamp(widgetRefreshDiagnostics.triggeredAt)) | \(source) | \(network)"
    }

    var widgetStatusTitle: String {
        guard let widgetRefreshDiagnostics else {
            return self.isRefreshing ? "Syncing" : "Idle"
        }

        return switch widgetRefreshDiagnostics.result {
        case .refreshed: "Updated"
        case .cached: "Cached"
        case .skipped: "Skipped"
        }
    }

    var widgetStatusDetail: String {
        guard let widgetRefreshDiagnostics else {
            return self.isRefreshing ? "refresh in progress" : "waiting for sync"
        }
        let requestLabel = widgetRefreshDiagnostics.requestCount == 1 ? "request" : "requests"
        return "#\(widgetRefreshDiagnostics.requestCount) \(requestLabel)"
    }

    private var hasConfiguredCredentials: Bool {
        self.codexAccessToken.nilIfBlank != nil
            || self.claudeAccessToken.nilIfBlank != nil
            || self.hasClaudeWebSession
    }

    private func refreshIfNeeded(force: Bool) async {
        guard self.hasConfiguredCredentials else { return }
        guard !self.isRefreshing else { return }
        guard self.activeBrowserLoginProvider == nil else { return }

        if !force,
           let generatedAt = self.snapshot?.generatedAt,
           Date().timeIntervalSince(generatedAt) < Self.automaticRefreshInterval
        {
            return
        }

        await self.refreshAll(silent: true)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
