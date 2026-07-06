import Foundation

public enum AmpProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .amp,
            metadata: ProviderMetadata(
                id: .amp,
                displayName: "Amp",
                sessionLabel: "Amp Free",
                weeklyLabel: "Balance",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: true,
                creditsHint: "Individual and workspace credit balances from Amp.",
                toggleTitle: "Show Amp usage",
                cliName: "amp",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://ampcode.com/settings/usage",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .amp,
                iconResourceName: "ProviderIcon-amp",
                color: ProviderColor(red: 220 / 255, green: 38 / 255, blue: 38 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Amp cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api, .web, .cli],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "amp",
                versionDetector: nil))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        switch context.sourceMode {
        case .auto:
            [AmpCLIFetchStrategy(), AmpAPIFetchStrategy(), AmpStatusFetchStrategy()]
        case .cli:
            [AmpCLIFetchStrategy()]
        case .api:
            [AmpAPIFetchStrategy()]
        case .web:
            [AmpStatusFetchStrategy()]
        case .oauth:
            []
        }
    }
}

struct AmpCLIFetchStrategy: ProviderFetchStrategy {
    let id: String = "amp.cli"
    let kind: ProviderFetchKind = .cli

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        BinaryLocator.resolveAmpBinary(
            env: context.env,
            loginPATH: LoginShellPathCache.shared.current) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let snapshot = try await AmpCLIProbe().fetch(environment: context.env)
        return self.makeResult(
            usage: snapshot.toUsageSnapshot(now: snapshot.updatedAt),
            sourceLabel: "cli")
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return false
        }
        return context.sourceMode == .auto
    }
}

struct AmpAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "amp.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        _ = context
        return true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let token = ProviderTokenResolver.ampToken(environment: context.env) else {
            throw AmpUsageError.missingAPIToken
        }
        let logger: ((String) -> Void)? = context.verbose
            ? { msg in CodexBarLog.logger(LogCategories.amp).verbose(msg) }
            : nil
        let snapshot = try await AmpUsageFetcher(browserDetection: context.browserDetection)
            .fetch(apiToken: token, logger: logger)
        return self.makeResult(
            usage: snapshot.toUsageSnapshot(now: snapshot.updatedAt),
            sourceLabel: "api")
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        guard context.sourceMode == .auto else { return false }
        return !(error is CancellationError) && (error as? URLError)?.code != .cancelled
    }
}

struct AmpStatusFetchStrategy: ProviderFetchStrategy {
    let id: String = "amp.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.sourceMode.usesWeb else { return false }
        #if os(macOS)
        let canImportBrowserCookies = true
        #else
        let canImportBrowserCookies = false
        #endif
        return Self.canUseWebFallback(
            settings: context.settings?.amp,
            canImportBrowserCookies: canImportBrowserCookies)
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let fetcher = AmpUsageFetcher(browserDetection: context.browserDetection)
        let manual = Self.manualCookieHeader(from: context)
        let logger: ((String) -> Void)? = context.verbose
            ? { msg in CodexBarLog.logger(LogCategories.amp).verbose(msg) }
            : nil
        let snap = try await fetcher.fetch(cookieHeaderOverride: manual, logger: logger)
        return self.makeResult(
            usage: snap.toUsageSnapshot(now: snap.updatedAt),
            sourceLabel: "web")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    static func canUseWebFallback(
        settings: ProviderSettingsSnapshot.AmpProviderSettings?,
        canImportBrowserCookies: Bool) -> Bool
    {
        guard let settings else { return canImportBrowserCookies }
        switch settings.cookieSource {
        case .auto:
            return canImportBrowserCookies
        case .manual:
            return Self.manualCookieHeader(from: settings.manualCookieHeader) != nil
        case .off:
            return false
        }
    }

    private static func manualCookieHeader(from context: ProviderFetchContext) -> String? {
        guard let settings = context.settings?.amp, settings.cookieSource == .manual else { return nil }
        return Self.manualCookieHeader(from: settings.manualCookieHeader)
    }

    private static func manualCookieHeader(from rawHeader: String?) -> String? {
        guard let header = CookieHeaderNormalizer.normalize(rawHeader),
              CookieHeaderNormalizer.pairs(from: header).contains(where: { $0.name == "session" })
        else { return nil }
        return header
    }
}
