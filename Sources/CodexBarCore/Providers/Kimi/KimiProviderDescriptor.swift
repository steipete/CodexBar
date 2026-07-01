import Foundation

public enum KimiProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .kimi,
            metadata: ProviderMetadata(
                id: .kimi,
                displayName: "Kimi",
                sessionLabel: "Session",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Kimi usage",
                cliName: "kimi",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://www.kimi.com/code/console",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .kimi,
                iconResourceName: "ProviderIcon-kimi",
                color: ProviderColor(red: 254 / 255, green: 96 / 255, blue: 60 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: { "No local Kimi Code session usage found." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "kimi",
                aliases: ["kimi-ai"],
                versionDetector: nil))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        switch context.sourceMode {
        case .api:
            [KimiAPIFetchStrategy()]
        case .web:
            [KimiWebFetchStrategy()]
        case .auto:
            [KimiAPIFetchStrategy(), KimiWebFetchStrategy()]
        case .cli, .oauth:
            []
        }
    }
}

struct KimiAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "kimi.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        if context.sourceMode == .api { return true }
        return await Self.resolveToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let resolution = await Self.resolveToken(
            environment: context.env,
            allowAuthFile: context.sourceMode != .api)
        else {
            throw KimiAPIError.missingAPIKey
        }
        let baseURL = try KimiSettingsReader.codeAPIBaseURL(environment: context.env)
        let identityHeaders = resolution.source == .authFile
            ? KimiSettingsReader.kimiCodeIdentityHeaders(environment: context.env)
            : [:]
        var snapshot = try await KimiUsageFetcher.fetchCodeAPIUsage(
            apiKey: resolution.token,
            baseURL: baseURL,
            identityHeaders: identityHeaders)
        if let modelDisplayName = try? await KimiUsageFetcher.fetchCodeAPIModelDisplayName(
            apiKey: resolution.token,
            baseURL: baseURL,
            identityHeaders: identityHeaders)
        {
            snapshot = snapshot.withModelDisplayName(modelDisplayName)
        }
        return self.makeResult(
            usage: snapshot.toUsageSnapshot(),
            sourceLabel: resolution.source == .authFile ? "Kimi Code credential" : "Kimi Code API key")
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        guard context.sourceMode == .auto else { return false }
        if error is CancellationError { return false }
        if let urlError = error as? URLError {
            return urlError.code != .cancelled
        }
        if case KimiAPIError.missingAPIKey = error { return true }
        if case KimiAPIError.invalidAPIKey = error { return true }
        if case KimiAPIError.apiError = error { return true }
        if error is DecodingError { return true }
        return false
    }

    private static func resolveToken(
        environment: [String: String],
        allowAuthFile: Bool = true) async -> ProviderTokenResolution?
    {
        if allowAuthFile {
            return await ProviderTokenResolver.kimiAPIResolutionRefreshing(environment: environment)
        }
        guard let token = KimiSettingsReader.apiKey(environment: environment) else { return nil }
        return ProviderTokenResolution(token: token, source: .environment)
    }
}

struct KimiWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "kimi.web"
    let kind: ProviderFetchKind = .web
    private static let log = CodexBarLog.logger(LogCategories.kimiWeb)

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        if KimiCookieHeader.resolveCookieOverride(context: context) != nil {
            return true
        }

        if Self.resolveToken(environment: context.env) != nil {
            return true
        }

        #if os(macOS)
        if context.settings?.kimi?.cookieSource != .off {
            return KimiCookieImporter.hasSession()
        }
        #endif

        return false
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let resolution = self.resolveToken(context: context) else {
            throw KimiAPIError.missingToken
        }

        let snapshot = try await KimiUsageFetcher.fetchUsage(authToken: resolution.token)
        return self.makeResult(
            usage: snapshot.toUsageSnapshot(),
            sourceLabel: resolution.sourceLabel)
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        if case KimiAPIError.missingToken = error { return false }
        if case KimiAPIError.invalidToken = error { return false }
        return true
    }

    private func resolveToken(context: ProviderFetchContext) -> (token: String, sourceLabel: String)? {
        // Check manual cookie first (highest priority when set)
        if let override = KimiCookieHeader.resolveCookieOverride(context: context) {
            return (override.token, "Kimi web cookie")
        }

        // Try browser cookie import when auto mode is enabled
        #if os(macOS)
        if context.settings?.kimi?.cookieSource != .off {
            do {
                let session = try KimiCookieImporter.importSession()
                if let token = session.authToken {
                    return (token, "Kimi web cookie")
                }
            } catch {
                // No browser cookies found
            }
        }
        #endif

        // Fall back to environment
        if let override = Self.resolveToken(environment: context.env) {
            return (override, "Kimi web cookie")
        }
        return nil
    }

    private static func resolveToken(environment: [String: String]) -> String? {
        ProviderTokenResolver.kimiAuthToken(environment: environment)
    }
}
