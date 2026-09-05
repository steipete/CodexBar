import Foundation

public enum KimiProviderDescriptor {
    public static let sessionWindowMinutes = 5 * 60
    public static let weeklyWindowMinutes = 7 * 24 * 60
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter(
        supportsAPIKeyOverride: true,
        environmentProjections: [
            .apiKey(KimiSettingsReader.apiKeyEnvironmentKeys[0]),
            .enterpriseHost(KimiSettingsReader.codeAPIBaseURLEnvironmentKey),
        ],
        tokenResolver: { kind, environment, _ in
            let token: String? = switch kind {
            case .primary: KimiSettingsReader.authToken(environment: environment)
            case .secondary: KimiSettingsReader.apiKey(environment: environment)
            case .projectID: nil
            }
            guard let token else { return nil }
            return ProviderTokenResolution(token: token, source: .environment)
        },
        authDetector: { environment, _ in
            var modes: [String] = []
            if KimiSettingsReader.apiKey(environment: environment) != nil {
                modes.append("api")
            }
            if KimiSettingsReader.authToken(environment: environment) != nil {
                modes.append("web")
            }
            return modes
        },
        missingCredentialMessage: { _ in KimiAPIError.missingToken.errorDescription })

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .kimi,
            settingsSection: .init(KimiProviderSettingsKey.self, cookieSettings: KimiProviderSettings.self),
            credentials: self.credentials,
            config: ProviderConfigCapabilities(supportsEnterpriseHost: true),
            metadata: ProviderMetadata(
                id: .kimi,
                displayName: "Kimi Code",
                sessionLabel: "7-day usage",
                weeklyLabel: "5-hour usage",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Kimi Code usage",
                cliName: "kimi",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                debugLogUnavailableMessage: "Kimi debug log not yet implemented",
                browserCookieOrder: nil,
                dashboardURL: "https://www.kimi.com/code/console",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .kimi),
                iconResourceName: "ProviderIcon-kimi",
                color: ProviderColor(red: 0 / 255, green: 124 / 255, blue: 255 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x000000),
                    ProviderColor(hex: 0x007CFF),
                    ProviderColor(hex: 0xFFFFFF),
                ],
                widgetColor: ProviderColor(red: 254 / 255, green: 96 / 255, blue: 60 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Kimi Code cost summary is not supported." }),
            pace: ProviderPaceCapability(
                resetWindowPace: .windowDuration(minutes: self.weeklyWindowMinutes),
                primary: .exact(kind: .weekly, minutes: self.weeklyWindowMinutes),
                secondary: .exact(kind: .session, minutes: self.sessionWindowMinutes),
                tertiary: .exact(kind: .session, minutes: self.sessionWindowMinutes),
                sessionPaceWindowRule: .windowDuration(minutes: self.sessionWindowMinutes)),
            presentation: ProviderUsagePresentation(
                semanticWindowResolver: { snapshot in
                    let candidates = [snapshot.primary, snapshot.secondary, snapshot.tertiary]
                        + (snapshot.extraRateWindows ?? []).map(\.window)
                    let usable = candidates.compactMap { window -> RateWindow? in
                        guard let window, !window.isSyntheticPlaceholder else { return nil }
                        return window
                    }
                    let session = usable.first { window in
                        guard let minutes = window.windowMinutes else { return false }
                        return (60...(12 * 60)).contains(minutes)
                    }
                    let cadenceWeekly = usable.first { $0.windowMinutes == 7 * 24 * 60 }
                    let primary = snapshot.primary.flatMap { $0.isSyntheticPlaceholder ? nil : $0 }
                    return ProviderSemanticWindows(session: session, weekly: primary ?? cadenceWeekly)
                },
                primarySemanticWindow: .weekly,
                secondarySemanticWindow: .session,
                menuBarWindowResolver: self.menuBarWindow,
                widgetRowLimitResolver: { _, _ in 3 },
                menuCard: ProviderMenuCardPresentation(resetWindowUsesWeeklyPace: true)),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "kimi",
                aliases: ["kimi-ai"],
                versionDetector: { _ in ProviderVersionDetector.kimiVersion() },
                browserSupportExemption: { sourceMode, environment, _ in
                    guard sourceMode == .auto else { return false }
                    return environment.map { environment in
                        ProviderTokenResolver.token(for: .kimi, kind: .secondary, environment: environment) != nil ||
                            KimiSettingsReader.hasKimiCodeCredential(environment: environment)
                    } == true
                }))
    }

    private static func menuBarWindow(
        context: ProviderMenuBarWindowContext) -> ProviderMenuBarWindowResolution
    {
        guard context.metric == .automatic else { return .unhandled }
        return .resolved(
            ProviderUsagePresentation.exhausted(context.snapshot.primary, context.snapshot.secondary)
                ?? context.snapshot.secondary
                ?? context.snapshot.primary)
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        switch context.sourceMode {
        case .api:
            [KimiAPIFetchStrategy()]
        case .web:
            [KimiWebFetchStrategy()]
        case .auto:
            [KimiAPIFetchStrategy(), KimiCLICredentialFetchStrategy(), KimiWebFetchStrategy()]
        case .cli, .oauth:
            []
        }
    }
}

struct KimiAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "kimi.api"
    let kind: ProviderFetchKind = .apiToken
    private let transport: any ProviderHTTPTransport
    private let resolveWebAuthToken: @Sendable (ProviderFetchContext) -> String?

    init(
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        resolveWebAuthToken: @escaping @Sendable (ProviderFetchContext) -> String? =
            KimiWebEnrichmentTokenResolver.resolve)
    {
        self.transport = transport
        self.resolveWebAuthToken = resolveWebAuthToken
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        context.sourceMode == .api || KimiSettingsReader.apiKey(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = KimiSettingsReader.apiKey(environment: context.env) else {
            throw KimiAPIError.missingAPIKey
        }
        let baseURL = try KimiSettingsReader.codeAPIBaseURL(environment: context.env)
        let snapshot = try await KimiUsageFetcher.fetchCodeAPIUsage(
            apiKey: apiKey,
            baseURL: baseURL,
            webAuthToken: self.enrichmentToken(context),
            transport: self.transport)
        return self.makeResult(
            usage: snapshot.toUsageSnapshot(),
            sourceLabel: "Kimi Code API key")
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        KimiCodeAPIFallbackPolicy.shouldFallback(on: error, context: context)
    }

    private func enrichmentToken(_ context: ProviderFetchContext) -> String? {
        guard let settings = context.settings?.kimi, settings.cookieSource != .off else { return nil }
        return self.resolveWebAuthToken(context)
    }
}

struct KimiCLICredentialFetchStrategy: ProviderFetchStrategy {
    let id: String = "kimi.cli"
    let kind: ProviderFetchKind = .oauth
    private let transport: any ProviderHTTPTransport
    private let resolveWebAuthToken: @Sendable (ProviderFetchContext) -> String?

    init(
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        resolveWebAuthToken: @escaping @Sendable (ProviderFetchContext) -> String? =
            KimiWebEnrichmentTokenResolver.resolve)
    {
        self.transport = transport
        self.resolveWebAuthToken = resolveWebAuthToken
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        context.sourceMode == .auto &&
            KimiSettingsReader.hasKimiCodeCredential(environment: context.env)
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let token = KimiSettingsReader.kimiCodeAccessToken(environment: context.env) else {
            throw KimiAPIError.expiredCodeCredential
        }
        let baseURL = try KimiSettingsReader.codeAPIBaseURL(environment: context.env)
        let identityHeaders = KimiSettingsReader.kimiCodeIdentityHeaders(environment: context.env)
        let snapshot: KimiUsageSnapshot
        do {
            snapshot = try await KimiUsageFetcher.fetchCodeAPIUsage(
                apiKey: token,
                baseURL: baseURL,
                identityHeaders: identityHeaders,
                webAuthToken: self.enrichmentToken(context),
                transport: self.transport)
        } catch {
            throw Self.normalizedCodeAPIError(error)
        }
        return self.makeResult(
            usage: snapshot.toUsageSnapshot(),
            sourceLabel: "Kimi Code CLI")
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        KimiCodeAPIFallbackPolicy.shouldFallback(on: error, context: context)
    }

    static func normalizedCodeAPIError(_ error: Error) -> Error {
        guard case KimiAPIError.invalidAPIKey = error else { return error }
        return KimiAPIError.invalidCodeCredential
    }

    private func enrichmentToken(_ context: ProviderFetchContext) -> String? {
        guard let settings = context.settings?.kimi, settings.cookieSource != .off else { return nil }
        return self.resolveWebAuthToken(context)
    }
}

enum KimiWebEnrichmentTokenResolver {
    static func resolve(_ context: ProviderFetchContext) -> String? {
        guard let settings = context.settings?.kimi, settings.cookieSource != .off else { return nil }
        if let override = KimiCookieHeader.resolveCookieOverride(context: context) {
            return override.token
        }
        #if os(macOS)
        if let token = KimiCookieImporter.desktopAuthToken() {
            return token
        }
        if let token = try? KimiCookieImporter.importSession().authToken {
            return token
        }
        #endif
        return nil
    }
}

private enum KimiCodeAPIFallbackPolicy {
    static func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        guard context.sourceMode == .auto else { return false }
        if error is CancellationError {
            return false
        }
        if let urlError = error as? URLError {
            return urlError.code != .cancelled
        }
        if case KimiAPIError.missingAPIKey = error {
            return true
        }
        if case KimiAPIError.expiredCodeCredential = error {
            return true
        }
        if case KimiAPIError.invalidCodeCredential = error {
            return true
        }
        if case KimiAPIError.invalidAPIKey = error {
            return true
        }
        if case KimiAPIError.apiError = error {
            return true
        }
        return error is DecodingError
    }
}

struct KimiWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "kimi.web"
    let kind: ProviderFetchKind = .web
    private static let log = CodexBarLog.logger(LogCategories.provider(.kimi, scope: "web"))

    private let fetchUsage: @Sendable (String) async throws -> KimiUsageSnapshot
    private let desktopToken: @Sendable () -> String?
    private let browserTokens: @Sendable () -> [String]

    init(
        fetchUsage: @escaping @Sendable (String) async throws -> KimiUsageSnapshot = {
            try await KimiUsageFetcher.fetchUsage(authToken: $0)
        },
        desktopToken: @escaping @Sendable () -> String? = {
            #if os(macOS)
            KimiCookieImporter.desktopAuthToken()
            #else
            nil
            #endif
        },
        browserTokens: @escaping @Sendable () -> [String] = {
            #if os(macOS)
            (try? KimiCookieImporter.importSessions().compactMap(\.authToken)) ?? []
            #else
            []
            #endif
        })
    {
        self.fetchUsage = fetchUsage
        self.desktopToken = desktopToken
        self.browserTokens = browserTokens
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        if KimiCookieHeader.resolveCookieOverride(context: context) != nil {
            return true
        }

        if Self.resolveToken(environment: context.env) != nil {
            return true
        }

        #if os(macOS)
        if KimiBrowserImportPolicy.allowsImport(context) {
            if KimiCookieImporter.desktopAuthToken() != nil {
                return true
            }
            return KimiCookieImporter.hasSession()
        }
        #endif

        return false
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        try Task.checkCancellation()
        // Explicit overrides stay authoritative; automatic sources may fall through on invalid credentials.
        if let override = KimiCookieHeader.resolveCookieOverride(context: context) {
            let snapshot = try await self.fetchUsage(override.token)
            return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: "Kimi web cookie")
        }
        var desktopToken: String?
        if KimiBrowserImportPolicy.allowsImport(context) {
            desktopToken = self.desktopToken()
        }
        let snapshot = try await Self.fetchWithFallback(
            desktopToken: desktopToken,
            browserTokens: {
                if KimiBrowserImportPolicy.allowsImport(context) {
                    return self.browserTokens()
                }
                return []
            },
            environmentToken: Self.resolveToken(environment: context.env),
            fetchUsage: self.fetchUsage)
        return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: "Kimi web cookie")
    }

    static func fetchWithFallback(
        desktopToken: String?,
        browserTokens: () -> [String],
        environmentToken: String?,
        fetchUsage: (String) async throws -> KimiUsageSnapshot) async throws -> KimiUsageSnapshot
    {
        try Task.checkCancellation()
        var seen = Set<String>()
        var invalidToken = false
        if let desktopToken {
            seen.insert(desktopToken)
            do {
                return try await fetchUsage(desktopToken)
            } catch KimiAPIError.invalidToken {
                invalidToken = true
            }
        }
        try Task.checkCancellation()
        for token in browserTokens() + [environmentToken].compactMap(\.self) where seen.insert(token).inserted {
            try Task.checkCancellation()
            do {
                return try await fetchUsage(token)
            } catch KimiAPIError.invalidToken {
                invalidToken = true
            }
        }
        try Task.checkCancellation()
        throw invalidToken ? KimiAPIError.invalidToken : KimiAPIError.missingToken
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        if case KimiAPIError.missingToken = error {
            return false
        }
        if case KimiAPIError.invalidToken = error {
            return false
        }
        return true
    }

    private static func resolveToken(environment: [String: String]) -> String? {
        ProviderTokenResolver.token(for: .kimi, environment: environment)
    }
}

enum KimiBrowserImportPolicy {
    static func allowsImport(_ context: ProviderFetchContext) -> Bool {
        context.settings?.kimi?.cookieSource != .off
    }
}
