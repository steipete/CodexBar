import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum GrokProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .grok,
            metadata: ProviderMetadata(
                id: .grok,
                displayName: "Grok",
                sessionLabel: "Credits",
                weeklyLabel: "On-demand",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Grok usage",
                cliName: "grok",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.grokCookieImportOrder,
                dashboardURL: "https://grok.com/?_s=usage",
                changelogURL: "https://x.ai/news",
                statusPageURL: nil,
                statusLinkURL: "https://status.x.ai"),
            branding: ProviderBranding(
                iconStyle: .grok,
                iconResourceName: "ProviderIcon-grok",
                color: ProviderColor(red: 16 / 255, green: 163 / 255, blue: 127 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Grok cost summary is not supported yet." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "grok",
                versionDetector: { _ in GrokStatusProbe.detectVersion() }))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        switch context.sourceMode {
        case .auto:
            [GrokCLIFetchStrategy(), GrokWebFetchStrategy()]
        case .cli:
            [GrokCLIFetchStrategy()]
        case .web:
            [GrokWebFetchStrategy()]
        case .api, .oauth:
            []
        }
    }

    /// Returns a contextual label for Grok's primary usage bar ("Weekly" or "Monthly").
    /// Prefer the billing period duration when available; fall back to reset distance for
    /// web billing payloads that expose only a reset timestamp.
    public static func primaryLabel(window: RateWindow?, now: Date = .now) -> String? {
        if let minutes = window?.windowMinutes {
            return self.primaryLabel(duration: TimeInterval(minutes) * 60)
        }
        return self.primaryLabel(resetsAt: window?.resetsAt, now: now)
    }

    public static func primaryLabel(resetsAt: Date?, now: Date = .now) -> String? {
        guard let resetsAt else { return nil }
        return self.primaryLabel(duration: resetsAt.timeIntervalSince(now))
    }

    private static func primaryLabel(duration seconds: TimeInterval) -> String? {
        guard seconds > 3600 else { return nil }
        let days = Int((seconds / 86400).rounded(.toNearestOrAwayFromZero))
        if (4...12).contains(days) { return "Weekly" }
        if (20...45).contains(days) { return "Monthly" }
        return nil
    }
}

struct GrokCLIFetchStrategy: ProviderFetchStrategy {
    let id: String = "grok.cli"
    let kind: ProviderFetchKind = .cli

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        BinaryLocator.resolveGrokBinary(env: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let probe = GrokStatusProbe()
        let snap = try await probe.fetch(env: context.env)
        return self.makeResult(
            usage: snap.toUsageSnapshot(),
            sourceLabel: "grok-cli")
    }

    func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
        context.sourceMode == .auto
    }
}

struct GrokWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "grok.web"
    let kind: ProviderFetchKind = .web

    static func canImportBrowserCookies(runtime: ProviderRuntime, env: [String: String]) -> Bool {
        runtime == .app || env["CODEXBAR_ALLOW_BROWSER_COOKIE_IMPORT"] == "1"
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        #if os(macOS)
        if Self.canImportBrowserCookies(runtime: context.runtime, env: context.env),
           GrokCookieImporter.hasSession(browserDetection: context.browserDetection)
        {
            return true
        }
        #endif
        return FileManager.default.fileExists(atPath: GrokCredentialsStore.authFileURL(env: context.env).path)
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let (webBilling, sourceLabel, authenticatedByAuthFile) = try await self.fetchWebBilling(context: context)
        let credentials = Self.credentialsForWebBillingSnapshot(
            credentials: try? GrokCredentialsStore.load(env: context.env),
            authenticatedByAuthFile: authenticatedByAuthFile)
        let snapshot = GrokUsageSnapshot(
            billing: nil,
            webBilling: webBilling,
            credentials: GrokStatusProbe.credentialsForSnapshot(
                credentials: credentials,
                billing: nil,
                webBilling: webBilling),
            localSummary: GrokLocalSessionScanner.summarize(env: context.env),
            cliVersion: GrokStatusProbe.detectVersion(env: context.env),
            updatedAt: Date())
        return self.makeResult(
            usage: snapshot.toUsageSnapshot(),
            sourceLabel: sourceLabel)
    }

    private func fetchWebBilling(context: ProviderFetchContext) async throws -> (
        snapshot: GrokWebBillingSnapshot,
        sourceLabel: String,
        authenticatedByAuthFile: Bool)
    {
        #if os(macOS)
        if Self.canImportBrowserCookies(runtime: context.runtime, env: context.env) {
            var lastCookieError: Error?
            do {
                let sessions = try GrokCookieImporter.importSessions(browserDetection: context.browserDetection)
                let (snapshot, sourceLabel) = try await Self.fetchFirstValidCookieSession(sessions)
                return (snapshot, sourceLabel, false)
            } catch {
                lastCookieError = error
            }
            if !FileManager.default.fileExists(atPath: GrokCredentialsStore.authFileURL(env: context.env).path) {
                throw lastCookieError ?? GrokWebBillingError.missingCredentials
            }
        }
        #endif

        let credentials = try GrokCredentialsStore.load(env: context.env)
        let snapshot = try await GrokWebBillingFetcher.fetch(credentials: credentials)
        return (snapshot, "grok-web", true)
    }

    static func credentialsForWebBillingSnapshot(
        credentials: GrokCredentials?,
        authenticatedByAuthFile: Bool) -> GrokCredentials?
    {
        authenticatedByAuthFile ? credentials : nil
    }

    #if os(macOS)
    static func fetchFirstValidCookieSession(
        _ sessions: [GrokCookieImporter.SessionInfo],
        fetch: (String) async throws -> GrokWebBillingSnapshot = { cookieHeader in
            try await GrokWebBillingFetcher.fetch(cookieHeader: cookieHeader)
        }) async throws -> (GrokWebBillingSnapshot, String)
    {
        var lastError: Error?
        for session in sessions {
            do {
                let snapshot = try await fetch(session.cookieHeader)
                return (snapshot, session.sourceLabel)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? GrokWebBillingError.missingCredentials
    }
    #endif

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
