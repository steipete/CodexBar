import CodexBarMacroSupport
import Foundation

#if os(macOS)
import SweetCookieKit
#endif

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum AlibabaCodingPlanProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        #if os(macOS)
        let browserOrder: BrowserCookieImportOrder = [
            .chrome,
            .chromeBeta,
            .brave,
            .edge,
            .arc,
            .firefox,
            .safari,
        ]
        #else
        let browserOrder: BrowserCookieImportOrder? = nil
        #endif

        return ProviderDescriptor(
            id: .alibaba,
            metadata: ProviderMetadata(
                id: .alibaba,
                displayName: "Alibaba",
                sessionLabel: "5-hour",
                weeklyLabel: "Weekly",
                opusLabel: "Monthly",
                supportsOpus: true,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Alibaba usage",
                cliName: "alibaba-coding-plan",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: browserOrder,
                dashboardURL: AlibabaCodingPlanAPIRegion.international.dashboardURL.absoluteString,
                statusPageURL: nil,
                statusLinkURL: "https://status.aliyun.com"),
            branding: ProviderBranding(
                iconStyle: .alibaba,
                iconResourceName: "ProviderIcon-alibaba",
                color: ProviderColor(red: 1.0, green: 106 / 255, blue: 0)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Alibaba Coding Plan cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "alibaba-coding-plan",
                aliases: ["alibaba", "bailian"],
                versionDetector: nil))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        switch context.sourceMode {
        case .web:
            return [AlibabaCodingPlanWebFetchStrategy()]
        case .api:
            return [AlibabaCodingPlanAPIFetchStrategy()]
        case .cli, .oauth:
            return []
        case .auto:
            break
        }

        if context.settings?.alibaba?.cookieSource == .off {
            return [AlibabaCodingPlanAPIFetchStrategy()]
        }

        return [AlibabaCodingPlanWebFetchStrategy(), AlibabaCodingPlanAPIFetchStrategy()]
    }
}

struct AlibabaCodingPlanWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "alibaba-coding-plan.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.alibaba?.cookieSource != .off else { return false }

        if AlibabaCodingPlanSettingsReader.cookieHeader(environment: context.env) != nil {
            return true
        }

        if let settings = context.settings?.alibaba,
           settings.cookieSource == .manual
        {
            return CookieHeaderNormalizer.normalize(settings.manualCookieHeader) != nil
        }

        #if os(macOS)
        if let cached = CookieHeaderCache.load(provider: .alibaba),
           !cached.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return true
        }
        if AlibabaCodingPlanCookieImporter.hasSession(browserDetection: context.browserDetection) {
            return true
        }
        return false
        #else
        return false
        #endif
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let cookieSource = context.settings?.alibaba?.cookieSource ?? .auto
        let cookieHeader = try Self.resolveCookieHeader(context: context, allowCached: true)
        do {
            let region = context.settings?.alibaba?.apiRegion ?? .international
            let usage = try await AlibabaCodingPlanUsageFetcher.fetchUsage(
                cookieHeader: cookieHeader,
                region: region,
                environment: context.env)
            return self.makeResult(usage: usage.toUsageSnapshot(), sourceLabel: "web")
        } catch let error as AlibabaCodingPlanUsageError
            where (error == .invalidCredentials || error == .loginRequired) && cookieSource != .manual
        {
            #if os(macOS)
            CookieHeaderCache.clear(provider: .alibaba)
            let refreshedHeader = try Self.resolveCookieHeader(context: context, allowCached: false)
            let region = context.settings?.alibaba?.apiRegion ?? .international
            let usage = try await AlibabaCodingPlanUsageFetcher.fetchUsage(
                cookieHeader: refreshedHeader,
                region: region,
                environment: context.env)
            return self.makeResult(usage: usage.toUsageSnapshot(), sourceLabel: "web")
            #else
            throw AlibabaCodingPlanUsageError.invalidCredentials
            #endif
        }
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        guard context.sourceMode == .auto else { return false }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .networkConnectionLost,
                 .dnsLookupFailed,
                 .secureConnectionFailed,
                 .serverCertificateHasBadDate,
                 .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid,
                 .clientCertificateRejected,
                 .clientCertificateRequired,
                 .cannotLoadFromNetwork,
                 .internationalRoamingOff,
                 .callIsActive,
                 .dataNotAllowed,
                 .requestBodyStreamExhausted,
                 .resourceUnavailable,
                 .notConnectedToInternet:
                return true
            default:
                break
            }
        }

        if let settingsError = error as? AlibabaCodingPlanSettingsError {
            switch settingsError {
            case .missingCookie, .invalidCookie:
                return true
            case .missingToken:
                return false
            }
        }

        guard let alibabaError = error as? AlibabaCodingPlanUsageError else { return false }
        switch alibabaError {
        case .loginRequired:
            return true
        case .invalidCredentials:
            return true
        case let .apiError(message):
            return message.contains("HTTP 404") || message.contains("HTTP 403")
        case .networkError:
            return true
        case .parseFailed:
            return false
        }
    }

    static func resolveCookieHeader(context: ProviderFetchContext, allowCached: Bool) throws -> String {
        if let settings = context.settings?.alibaba,
           settings.cookieSource == .manual
        {
            guard let header = CookieHeaderNormalizer.normalize(settings.manualCookieHeader) else {
                throw AlibabaCodingPlanSettingsError.invalidCookie
            }
            return header
        }

        if let envCookie = AlibabaCodingPlanSettingsReader.cookieHeader(environment: context.env),
           let normalized = CookieHeaderNormalizer.normalize(envCookie)
        {
            return normalized
        }

        #if os(macOS)
        if allowCached,
           let cached = CookieHeaderCache.load(provider: .alibaba),
           !cached.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return cached.cookieHeader
        }

        do {
            let session = try AlibabaCodingPlanCookieImporter.importSession(browserDetection: context.browserDetection)
            CookieHeaderCache.store(
                provider: .alibaba,
                cookieHeader: session.cookieHeader,
                sourceLabel: session.sourceLabel)
            return session.cookieHeader
        } catch {
            throw error
        }
        #else
        throw AlibabaCodingPlanSettingsError.missingCookie()
        #endif
    }
}

struct AlibabaCodingPlanAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "alibaba-coding-plan.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Self.resolveToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = Self.resolveToken(environment: context.env) else {
            throw AlibabaCodingPlanSettingsError.missingToken
        }
        let region = context.settings?.alibaba?.apiRegion ?? .international
        let usage = try await AlibabaCodingPlanUsageFetcher.fetchUsage(
            apiKey: apiKey,
            region: region,
            environment: context.env)
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func resolveToken(environment: [String: String]) -> String? {
        ProviderTokenResolver.alibabaToken(environment: environment)
    }
}
