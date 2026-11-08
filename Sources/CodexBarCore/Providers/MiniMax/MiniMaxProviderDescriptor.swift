import Foundation

public enum MiniMaxProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter(
        supportsAPIKeyOverride: true,
        usesRegion: true,
        environmentProjections: [.apiKey(MiniMaxAPISettingsReader.apiTokenKey)],
        tokenResolver: { kind, environment, _ in
            let token: String? = switch kind {
            case .primary: MiniMaxAPISettingsReader.apiToken(environment: environment)
            case .secondary: MiniMaxSettingsReader.cookieHeader(environment: environment)
            case .projectID: nil
            }
            guard let token else { return nil }
            return ProviderTokenResolution(token: token, source: .environment)
        },
        tokenAccountSupport: TokenAccountSupport(
            title: "Session tokens",
            subtitle: "Store multiple MiniMax Cookie headers.",
            placeholder: "Cookie: …",
            injection: .cookieHeader,
            requiresManualCookieSource: true,
            cookieName: nil),
        diagnosticSummary: { _, _, environment, settings in
            let apiToken = MiniMaxAPISettingsReader.apiToken(environment: environment)
            let cookie = MiniMaxSettingsReader.cookieHeader(environment: environment)
                ?? CookieHeaderNormalizer.normalize(settings?.minimax?.manualCookieHeader)
            let mode = MiniMaxAuthMode.resolve(apiToken: apiToken, cookieHeader: cookie)
            return ProviderDiagnosticAuthSummary(
                configured: mode.usesAPIToken || mode.usesCookie,
                modes: mode == .none ? [] : [mode.description])
        },
        configValidator: ProviderCredentialAdapter.regionValidator(
            displayName: "MiniMax",
            isValid: { MiniMaxAPIRegion(rawValue: $0) != nil }),
        missingCredentialMessage: { _ in MiniMaxAPISettingsError.missingToken.errorDescription })

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .minimax,
            settingsSection: .init(
                MiniMaxProviderSettingsKey.self,
                cookieSettings: { settings in
                    CookieProviderSettings(
                        cookieSource: settings.cookieSource,
                        manualCookieHeader: settings.manualCookieHeader)
                },
                credentialSettings: { context in
                    let settings = context.cookieSettings(for: .minimax)
                    let region = context.config?.sanitizedRegion
                        .flatMap(MiniMaxAPIRegion.init(rawValue:)) ?? .global
                    return MiniMaxProviderSettings(
                        cookieSource: settings.cookieSource,
                        manualCookieHeader: settings.manualCookieHeader,
                        apiRegion: region)
                }),
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .minimax,
                displayName: "MiniMax",
                sessionLabel: "Prompts",
                weeklyLabel: "Window",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show MiniMax usage",
                cliName: "minimax",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                sharePlanLabels: [
                    "free": "Free", "pro": "Pro", "plus": "Plus", "max": "Max", "ultra": "Ultra",
                    "minimax star": "MiniMax Star", "combo star": "Combo Star", "coding plan pro": "Coding Plan Pro",
                    "token plan pro": "Token Plan Pro", "token plan · tokenplanplus-年度会员": "Token Plan Plus",
                    "tokenplanplus-年度会员": "Token Plan Plus", "tokenplanmax-年度会员": "Token Plan Max",
                    "tokenplanultra-年度会员": "Token Plan Ultra",
                ],
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://platform.minimax.io/user-center/payment/coding-plan?cycle_type=3",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .minimax),
                iconResourceName: "ProviderIcon-minimax",
                color: ProviderColor(red: 254 / 255, green: 96 / 255, blue: 60 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x181E25),
                    ProviderColor(hex: 0x86909C),
                    ProviderColor(hex: 0xF7F8FA),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "MiniMax cost summary is not supported." }),
            presentation: ProviderUsagePresentation(
                costPresenter: { snapshot in
                    let style: ProviderCostMenuCardStyle = snapshot.providerCost?.period == "MiniMax points balance"
                        ? .pointsBalance
                        : .generic
                    return ProviderCostPresentation(menuCardStyle: style)
                },
                automaticSelectionPrioritizesExhaustedWindow: false,
                menuBarWindowResolver: { context in
                    guard context.metric == .automatic else { return .unhandled }
                    return .automaticCandidates([
                        context.snapshot.primary,
                        context.snapshot.secondary,
                        context.snapshot.tertiary,
                    ].compactMap(\.self))
                },
                optionalDetails: ProviderOptionalDetailsPresentation(
                    hiddenTitlesWithoutOptionalUsage: ["Billing history"],
                    costSummaryTitles: ["Billing history"])),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "minimax",
                aliases: ["mini-max"],
                versionDetector: nil,
                browserSupportExemption: { sourceMode, environment, _ in
                    // Standard sk-api keys select the Coding Plan web strategy; other tokens use HTTPS directly.
                    guard sourceMode == .auto, let environment,
                          MiniMaxAPISettingsReader.apiToken(environment: environment) != nil else { return false }
                    return MiniMaxAPISettingsReader.apiKeyKind(environment: environment) != .standard
                }))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        switch context.sourceMode {
        case .web:
            return [MiniMaxCodingPlanFetchStrategy()]
        case .api:
            return [MiniMaxAPIFetchStrategy()]
        case .cli, .oauth:
            return []
        case .auto:
            break
        }
        let apiToken = ProviderTokenResolver.token(for: .minimax, environment: context.env)
        let apiKeyKind = MiniMaxAPISettingsReader.apiKeyKind(token: apiToken)
        let authMode = MiniMaxAuthMode.resolve(
            apiToken: apiToken,
            cookieHeader: ProviderTokenResolver.token(for: .minimax, kind: .secondary, environment: context.env))
        if authMode.usesAPIToken {
            if apiKeyKind == .standard {
                return [MiniMaxCodingPlanFetchStrategy()]
            }
            return [MiniMaxAPIFetchStrategy(), MiniMaxCodingPlanFetchStrategy()]
        }
        return [MiniMaxCodingPlanFetchStrategy()]
    }
}

struct MiniMaxAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "minimax.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        let authMode = MiniMaxAuthMode.resolve(
            apiToken: ProviderTokenResolver.token(for: .minimax, environment: context.env),
            cookieHeader: ProviderTokenResolver.token(for: .minimax, kind: .secondary, environment: context.env))
        if let kind = MiniMaxAPISettingsReader.apiKeyKind(environment: context.env),
           kind == .standard
        {
            return false
        }
        return authMode.usesAPIToken
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiToken = ProviderTokenResolver.token(for: .minimax, environment: context.env) else {
            throw MiniMaxAPISettingsError.missingToken
        }
        let region = context.settings?.minimax?.apiRegion ?? .global
        let usage = try await MiniMaxUsageFetcher.fetchUsage(apiToken: apiToken, region: region)
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on error: Error, context _: ProviderFetchContext) -> Bool {
        guard let minimaxError = error as? MiniMaxUsageError else { return false }
        switch minimaxError {
        case .invalidCredentials:
            return true
        case let .apiError(message):
            return message.contains("HTTP 404")
        case .networkError, .parseFailed:
            return false
        }
    }
}

struct MiniMaxCodingPlanFetchStrategy: ProviderFetchStrategy {
    let id: String = "minimax.web"
    let kind: ProviderFetchKind = .web
    private static let log = CodexBarLog.logger(LogCategories.provider(.minimax, scope: "web"))

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        if Self.resolveCookieOverride(context: context) != nil {
            return true
        }
        guard (context.settings?.minimax?.cookieSource ?? .auto) == .auto else { return false }
        #if os(macOS)
        let region = context.settings?.minimax?.apiRegion ?? .global
        for domain in MiniMaxWebSessionDomain.candidates(for: region) {
            if let cached = CookieHeaderCache.load(provider: .minimax, scope: domain.cacheScope),
               !cached.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return true
            }
        }
        guard Self.allowsBrowserCookieImport(context: context) else {
            return false
        }
        return MiniMaxCookieImporter.hasSession(
            browserDetection: context.browserDetection,
            region: region,
            environment: context.env)
        #else
        return false
        #endif
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let fetchContext = FetchContext(
            region: context.settings?.minimax?.apiRegion ?? .global,
            environment: context.env,
            includeBillingHistory: context.includeOptionalUsage)
        if let override = Self.resolveCookieOverride(context: context) {
            Self.log.debug("Using MiniMax cookie header from settings/env")
            let snapshot = try await MiniMaxUsageFetcher.fetchUsage(
                cookieHeader: override.cookieHeader,
                authorizationToken: override.authorizationToken,
                groupID: override.groupID,
                region: fetchContext.region,
                environment: fetchContext.environment,
                includeBillingHistory: context.includeOptionalUsage)
            return self.makeResult(
                usage: snapshot.toUsageSnapshot(),
                sourceLabel: "web")
        }

        #if os(macOS)
        guard (context.settings?.minimax?.cookieSource ?? .auto) == .auto else {
            throw MiniMaxSettingsError.missingCookie
        }
        let domains = MiniMaxWebSessionDomain.candidates(for: fetchContext.region)
        var observations = Dictionary(uniqueKeysWithValues: domains.map { domain in
            (domain, CookieHeaderCache.observeForConditionalMutation(provider: .minimax, scope: domain.cacheScope))
        })
        let cached = domains.compactMap { domain -> MiniMaxWebSession? in
            guard let entry = observations[domain]?.entry else { return nil }
            return MiniMaxWebSession(cookieHeader: entry.cookieHeader, sourceLabel: entry.sourceLabel, domain: domain)
        }
        let snapshot = try await Self.fetchAutomatic(
            cached: cached,
            fetchSession: { session in
                let tokenContext = session.usesTokenCookie
                    ? TokenContext(tokensByLabel: [:], groupIDByLabel: [:])
                    : Self.loadTokenContext(browserDetection: context.browserDetection, domain: session.domain)
                return try await Self.fetchSession(session, tokenContext: tokenContext, fetchContext: fetchContext)
            },
            browserSessions: {
                guard Self.allowsBrowserCookieImport(context: context) else { return AnySequence([]) }
                return (try? MiniMaxCookieImporter.webSessionCandidates(
                    browserDetection: context.browserDetection,
                    region: fetchContext.region,
                    environment: fetchContext.environment)) ?? AnySequence([])
            },
            clearCached: { session in
                guard let observation = observations[session.domain] else { return }
                if CookieHeaderCache.clearIfCurrent(
                    provider: .minimax, scope: session.domain.cacheScope, expected: observation.entry)
                {
                    observations[session.domain] = observation.afterOwnedClear()
                }
            },
            storeResolved: { session in
                guard let observation = observations[session.domain] else { return }
                CookieHeaderCache.storeIfObservationCurrent(
                    provider: .minimax,
                    scope: session.domain.cacheScope,
                    expected: observation,
                    cookieHeader: session.cookieHeader,
                    sourceLabel: session.sourceLabel)
            })
        return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: "web")
        #endif
        #if !os(macOS)
        throw MiniMaxSettingsError.missingCookie
        #endif
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    static func allowsBrowserCookieImport(context: ProviderFetchContext) -> Bool {
        guard context.runtime == .app else { return false }
        // The shared access gate permits background reads only when Keychain access needs no UI.
        return (context.settings?.minimax?.cookieSource ?? .auto) == .auto
    }

    static func fetchAutomatic(
        cached: [MiniMaxWebSession],
        fetchSession: (MiniMaxWebSession) async throws -> MiniMaxUsageSnapshot,
        browserSessions: () -> AnySequence<MiniMaxWebSession>,
        clearCached: (MiniMaxWebSession) -> Void,
        storeResolved: (MiniMaxWebSession) -> Void) async throws -> MiniMaxUsageSnapshot
    {
        var lastError: Error?
        for session in cached {
            do {
                return try await fetchSession(session)
            } catch {
                guard Self.shouldTryNextBrowser(for: error) else { throw error }
                lastError = error
                if case MiniMaxUsageError.invalidCredentials = error { clearCached(session) }
            }
        }
        for session in browserSessions() {
            do {
                let snapshot = try await fetchSession(session)
                storeResolved(session)
                return snapshot
            } catch {
                guard Self.shouldTryNextBrowser(for: error) else { throw error }
                lastError = error
            }
        }
        if let lastError { throw lastError }
        throw MiniMaxSettingsError.missingCookie
    }

    private struct TokenContext {
        struct Token {
            let value: String
            let groupID: String?
        }

        let tokensByLabel: [String: [Token]]
        let groupIDByLabel: [String: String]
    }

    private struct FetchContext {
        let region: MiniMaxAPIRegion
        @ProcessEnvironment private(set) var environment: [String: String]
        let includeBillingHistory: Bool
    }

    private static func resolveCookieOverride(context: ProviderFetchContext) -> MiniMaxCookieOverride? {
        if let settings = context.settings?.minimax {
            guard settings.cookieSource == .manual else { return nil }
            return MiniMaxCookieHeader.override(from: settings.manualCookieHeader)
        }
        guard let raw = ProviderTokenResolver.token(for: .minimax, kind: .secondary, environment: context.env) else {
            return nil
        }
        return MiniMaxCookieHeader.override(from: raw)
    }

    private static func normalizeStorageLabel(_ label: String) -> String {
        let suffixes = [" (Session Storage)", " (IndexedDB)"]
        for suffix in suffixes where label.hasSuffix(suffix) {
            return String(label.dropLast(suffix.count))
        }
        return label
    }

    private static func loadTokenContext(
        browserDetection: BrowserDetection,
        domain: MiniMaxWebSessionDomain) -> TokenContext
    {
        #if os(macOS)
        let tokenLog: (String) -> Void = { msg in Self.log.debug(msg) }
        let accessTokens = MiniMaxLocalStorageImporter.importAccessTokens(
            browserDetection: browserDetection,
            domain: domain,
            logger: tokenLog)
        let groupIDs = MiniMaxLocalStorageImporter.importGroupIDs(
            browserDetection: browserDetection,
            domain: domain,
            logger: tokenLog)
        var tokensByLabel: [String: [TokenContext.Token]] = [:]
        var groupIDByLabel: [String: String] = [:]
        for token in accessTokens {
            let normalized = Self.normalizeStorageLabel(token.sourceLabel)
            tokensByLabel[normalized, default: []].append(.init(value: token.accessToken, groupID: token.groupID))
            if let groupID = token.groupID, groupIDByLabel[normalized] == nil {
                groupIDByLabel[normalized] = groupID
            }
        }
        for (label, groupID) in groupIDs {
            let normalized = Self.normalizeStorageLabel(label)
            if groupIDByLabel[normalized] == nil {
                groupIDByLabel[normalized] = groupID
            }
        }
        return TokenContext(tokensByLabel: tokensByLabel, groupIDByLabel: groupIDByLabel)
        #else
        _ = browserDetection
        _ = domain
        return TokenContext(tokensByLabel: [:], groupIDByLabel: [:])
        #endif
    }

    private static func fetchSession(
        _ session: MiniMaxWebSession,
        tokenContext: TokenContext,
        fetchContext: FetchContext) async throws -> MiniMaxUsageSnapshot
    {
        let normalizedLabel = Self.normalizeStorageLabel(session.sourceLabel)
        let environment = session.domain.environment(fetchContext.environment)
        let tokenCandidates = (tokenContext.tokensByLabel[normalizedLabel] ?? []).filter { token in
            Self.isCompatibleGroupID(token.groupID, sessionGroupID: session.groupID)
        }
        let cookieToken = Self.cookieValue(named: "HERTZ-SESSION", in: session.cookieHeader)
        let attempts = Self.authorizationCandidates(
            cookieHeader: session.cookieHeader,
            tokens: tokenCandidates.map(\.value),
            domain: session.domain)

        var lastError: Error?
        for token in attempts {
            let groupID = session.groupID
                ?? tokenCandidates.first(where: { $0.value == token })?.groupID
                ?? tokenContext.groupIDByLabel[normalizedLabel]
            let tokenLabel: String = {
                guard let token else { return "" }
                if token == cookieToken {
                    return " + HERTZ-SESSION bearer"
                }
                return " + access token"
            }()
            Self.log.debug("Trying MiniMax cookies from \(session.sourceLabel)\(tokenLabel)")
            do {
                let snapshot = try await MiniMaxUsageFetcher.fetchUsage(
                    cookieHeader: session.cookieHeader,
                    authorizationToken: token,
                    groupID: groupID,
                    region: fetchContext.region,
                    environment: environment,
                    includeBillingHistory: fetchContext.includeBillingHistory)
                Self.log.debug("MiniMax cookies valid from \(session.sourceLabel)")
                return snapshot
            } catch {
                lastError = error
                if Self.shouldTryNextBrowser(for: error) {
                    continue
                }
                throw error
            }
        }

        if let lastError {
            throw lastError
        }
        throw MiniMaxSettingsError.missingCookie
    }

    static func authorizationCandidates(
        cookieHeader: String,
        tokens: [String],
        domain: MiniMaxWebSessionDomain) -> [String?]
    {
        // A browser's _token is the selected session; unrelated storage bearers must not replace its account.
        if domain == .chinaMainland, let token = cookieValue(named: "_token", in: cookieHeader), !token.isEmpty {
            return [nil]
        }
        var attempts: [String?] = []
        for token in tokens where !attempts.contains(where: { $0 == token }) {
            attempts.append(token)
        }
        if let cookieToken = self.cookieValue(named: "HERTZ-SESSION", in: cookieHeader),
           !attempts.contains(where: { $0 == cookieToken })
        {
            attempts.append(cookieToken)
        }
        attempts.append(nil)
        return attempts
    }

    static func isCompatibleGroupID(_ candidate: String?, sessionGroupID: String?) -> Bool {
        // Opaque tokens can lack group claims; only an explicit mismatch rejects a same-host/profile candidate.
        candidate == nil || sessionGroupID == nil || candidate == sessionGroupID
    }

    private static func cookieValue(named name: String, in header: String) -> String? {
        let parts = header.split(separator: ";")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("\(name.lowercased())=") else { continue }
            return String(trimmed.dropFirst(name.count + 1))
        }
        return nil
    }

    private static func shouldTryNextBrowser(for error: Error) -> Bool {
        if case MiniMaxUsageError.invalidCredentials = error {
            return true
        }
        if case MiniMaxUsageError.parseFailed = error {
            return true
        }
        return false
    }
}
