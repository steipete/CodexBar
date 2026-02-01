import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum MiniMaxProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .minimax,
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
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://platform.minimax.io/user-center/payment/coding-plan?cycle_type=3",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .minimax,
                iconResourceName: "ProviderIcon-minimax",
                color: ProviderColor(red: 254 / 255, green: 96 / 255, blue: 60 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "MiniMax cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "minimax",
                aliases: ["mini-max"],
                versionDetector: nil))
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
        let apiToken = ProviderTokenResolver.minimaxToken(environment: context.env)
        let apiKeyKind = MiniMaxAPISettingsReader.apiKeyKind(token: apiToken)
        let authMode = MiniMaxAuthMode.resolve(
            apiToken: apiToken,
            cookieHeader: ProviderTokenResolver.minimaxCookie(environment: context.env))
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
            apiToken: ProviderTokenResolver.minimaxToken(environment: context.env),
            cookieHeader: ProviderTokenResolver.minimaxCookie(environment: context.env))
        if let kind = MiniMaxAPISettingsReader.apiKeyKind(environment: context.env),
           kind == .standard
        {
            return false
        }
        return authMode.usesAPIToken
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiToken = ProviderTokenResolver.minimaxToken(environment: context.env) else {
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
    private static let log = CodexBarLog.logger(LogCategories.minimaxWeb)

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        if Self.resolveCookieOverride(context: context) != nil {
            return true
        }
        #if os(macOS)
        if let cached = CookieHeaderCache.load(provider: .minimax),
           !cached.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return true
        }
        return MiniMaxCookieImporter.hasSession(browserDetection: context.browserDetection)
        #else
        return false
        #endif
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let fetchContext = FetchContext(
            region: context.settings?.minimax?.apiRegion ?? .global,
            environment: context.env)
        if let override = Self.resolveCookieOverride(context: context) {
            Self.log.debug("Using MiniMax cookie header from settings/env")
            let snapshot = try await MiniMaxUsageFetcher.fetchUsage(
                cookieHeader: override.cookieHeader,
                authorizationToken: override.authorizationToken,
                groupID: override.groupID,
                region: fetchContext.region,
                environment: fetchContext.environment)
            return self.makeResult(
                usage: snapshot.toUsageSnapshot(),
                sourceLabel: "web")
        }

        #if os(macOS)
        let tokenContext = Self.loadTokenContext(browserDetection: context.browserDetection)

        var lastError: Error?
        if let cached = CookieHeaderCache.load(provider: .minimax),
           !cached.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            switch await Self.attemptFetch(
                cookieHeader: cached.cookieHeader,
                sourceLabel: cached.sourceLabel,
                tokenContext: tokenContext,
                logLabel: "cached",
                fetchContext: fetchContext)
            {
            case let .success(snapshot):
                return self.makeResult(
                    usage: snapshot.toUsageSnapshot(),
                    sourceLabel: "web")
            case let .failure(error):
                lastError = error
                if Self.shouldTryNextBrowser(for: error) {
                    CookieHeaderCache.clear(provider: .minimax)
                } else {
                    throw error
                }
            }
        }

        let sessions = (try? MiniMaxCookieImporter.importSessions(
            browserDetection: context.browserDetection)) ?? []
        guard !sessions.isEmpty else {
            if let lastError { throw lastError }
            throw MiniMaxSettingsError.missingCookie
        }

        for session in sessions {
            switch await Self.attemptFetch(
                cookieHeader: session.cookieHeader,
                sourceLabel: session.sourceLabel,
                tokenContext: tokenContext,
                logLabel: "",
                fetchContext: fetchContext)
            {
            case let .success(snapshot):
                CookieHeaderCache.store(
                    provider: .minimax,
                    cookieHeader: session.cookieHeader,
                    sourceLabel: session.sourceLabel)
                return self.makeResult(
                    usage: snapshot.toUsageSnapshot(),
                    sourceLabel: "web")
            case let .failure(error):
                lastError = error
                if Self.shouldTryNextBrowser(for: error) {
                    Self.log.debug("MiniMax cookies invalid from \(session.sourceLabel), trying next browser")
                    continue
                }
                throw error
            }
        }

        if let lastError {
            throw lastError
        }
        #endif

        throw MiniMaxSettingsError.missingCookie
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private struct TokenContext: Sendable {
        let tokensByLabel: [String: [String]]
        let groupIDByLabel: [String: String]
    }

    private struct FetchContext: Sendable {
        let region: MiniMaxAPIRegion
        let environment: [String: String]
    }

    private enum FetchAttemptResult: Sendable {
        case success(MiniMaxUsageSnapshot)
        case failure(Error)
    }

    private static func resolveCookieOverride(context: ProviderFetchContext) -> MiniMaxCookieOverride? {
        if let settings = context.settings?.minimax {
            guard settings.cookieSource == .manual else { return nil }
            return MiniMaxCookieHeader.override(from: settings.manualCookieHeader)
        }
        guard let raw = ProviderTokenResolver.minimaxCookie(environment: context.env) else {
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

    private static func loadTokenContext(browserDetection: BrowserDetection) -> TokenContext {
        #if os(macOS)
        let tokenLog: (String) -> Void = { msg in Self.log.debug(msg) }
        let accessTokens = MiniMaxLocalStorageImporter.importAccessTokens(
            browserDetection: browserDetection,
            logger: tokenLog)
        let groupIDs = MiniMaxLocalStorageImporter.importGroupIDs(
            browserDetection: browserDetection,
            logger: tokenLog)
        var tokensByLabel: [String: [String]] = [:]
        var groupIDByLabel: [String: String] = [:]
        for token in accessTokens {
            let normalized = Self.normalizeStorageLabel(token.sourceLabel)
            tokensByLabel[normalized, default: []].append(token.accessToken)
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
        return TokenContext(tokensByLabel: [:], groupIDByLabel: [:])
        #endif
    }

    private static func attemptFetch(
        cookieHeader: String,
        sourceLabel: String,
        tokenContext: TokenContext,
        logLabel: String,
        fetchContext: FetchContext) async -> FetchAttemptResult
    {
        let normalizedLabel = Self.normalizeStorageLabel(sourceLabel)
        let tokenCandidates = tokenContext.tokensByLabel[normalizedLabel] ?? []
        let groupID = tokenContext.groupIDByLabel[normalizedLabel]
        let cookieToken = Self.cookieValue(named: "HERTZ-SESSION", in: cookieHeader)
        var attempts: [String?] = tokenCandidates.map(\.self)
        if let cookieToken, !tokenCandidates.contains(cookieToken) {
            attempts.append(cookieToken)
        }
        attempts.append(nil)

        let prefix = logLabel.isEmpty ? "" : "\(logLabel) "
        var lastError: Error?
        for token in attempts {
            let tokenLabel: String = {
                guard let token else { return "" }
                if token == cookieToken { return " + HERTZ-SESSION bearer" }
                return " + access token"
            }()
            Self.log.debug("Trying MiniMax \(prefix)cookies from \(sourceLabel)\(tokenLabel)")
            do {
                let snapshot = try await MiniMaxUsageFetcher.fetchUsage(
                    cookieHeader: cookieHeader,
                    authorizationToken: token,
                    groupID: groupID,
                    region: fetchContext.region,
                    environment: fetchContext.environment)
                Self.log.debug("MiniMax \(prefix)cookies valid from \(sourceLabel)")
                return .success(snapshot)
            } catch {
                lastError = error
                if Self.shouldTryNextBrowser(for: error) {
                    continue
                }
                return .failure(error)
            }
        }

        if let lastError {
            return .failure(lastError)
        }
        return .failure(MiniMaxSettingsError.missingCookie)
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
        if case MiniMaxUsageError.invalidCredentials = error { return true }
        if case MiniMaxUsageError.parseFailed = error { return true }
        return false
    }
}
