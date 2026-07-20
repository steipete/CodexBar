import Foundation

#if os(macOS)
import SweetCookieKit
#endif

public enum QwenCloudProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

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
            id: .qwencloud,
            metadata: ProviderMetadata(
                id: .qwencloud,
                displayName: "Qwen Cloud",
                sessionLabel: "Credits",
                weeklyLabel: "Usage",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Qwen Cloud usage",
                cliName: "qwen-cloud",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: browserOrder,
                dashboardURL: QwenCloudUsageFetcher.dashboardURL.absoluteString,
                statusPageURL: nil,
                statusLinkURL: "https://status.alibabacloud.com"),
            branding: ProviderBranding(
                iconStyle: .qwencloud,
                iconResourceName: "ProviderIcon-qwencloud",
                color: ProviderColor(hex: 0x615CED),
                confettiPalette: [
                    ProviderColor(hex: 0x615CED),
                    ProviderColor(hex: 0x8B86F5),
                    ProviderColor(hex: 0xFFFFFF),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Qwen Cloud cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "qwen-cloud",
                aliases: ["qwencloud", "qwen", "qwen-token-plan"],
                versionDetector: nil))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        guard context.settings?.qwenCloud?.cookieSource != .off else { return [] }
        switch context.sourceMode {
        case .auto, .web:
            return [QwenCloudWebFetchStrategy()]
        case .api, .cli, .oauth:
            return []
        }
    }
}

struct QwenCloudWebFetchStrategy: ProviderFetchStrategy {
    private static let log = CodexBarLog.logger("qwen-cloud")

    let id: String = "qwen-cloud.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.qwenCloud?.cookieSource != .off else { return false }

        if QwenCloudSettingsReader.cookieHeader(environment: context.env) != nil {
            return true
        }

        if let settings = context.settings?.qwenCloud,
           settings.cookieSource == .manual
        {
            return CookieHeaderNormalizer.normalize(settings.manualCookieHeader) != nil
        }

        #if os(macOS)
        if let cached = CookieHeaderCache.load(provider: .qwencloud),
           !cached.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return true
        }
        return true
        #else
        return false
        #endif
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let cookieSource = context.settings?.qwenCloud?.cookieSource ?? .auto
        let cookieHeaders = try Self.resolveCookieHeaders(context: context, allowCached: true)
        do {
            let usage = try await QwenCloudUsageFetcher.fetchUsage(
                apiCookieHeader: cookieHeaders.apiCookieHeader,
                dashboardCookieHeader: cookieHeaders.dashboardCookieHeader,
                environment: context.env)
            return self.makeResult(usage: usage.toUsageSnapshot(), sourceLabel: "web")
        } catch let error as QwenCloudUsageError
            where error.isCredentialFailure && cookieSource != .manual
        {
            #if os(macOS)
            CookieHeaderCache.clear(provider: .qwencloud)
            let refreshedHeaders = try Self.resolveCookieHeaders(context: context, allowCached: false)
            let usage = try await QwenCloudUsageFetcher.fetchUsage(
                apiCookieHeader: refreshedHeaders.apiCookieHeader,
                dashboardCookieHeader: refreshedHeaders.dashboardCookieHeader,
                environment: context.env)
            return self.makeResult(usage: usage.toUsageSnapshot(), sourceLabel: "web")
            #else
            throw error
            #endif
        }
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    static func resolveCookieHeader(context: ProviderFetchContext, allowCached: Bool) throws -> String {
        try self.resolveCookieHeaders(context: context, allowCached: allowCached).apiCookieHeader
    }

    static func resolveCookieHeaders(
        context: ProviderFetchContext,
        allowCached: Bool) throws -> QwenCloudCookieHeaders
    {
        if let settings = context.settings?.qwenCloud,
           settings.cookieSource == .manual
        {
            guard let headers = QwenCloudCookieHeaders(singleHeader: settings.manualCookieHeader) else {
                self.log.warning("Qwen Cloud manual cookie header is invalid")
                throw QwenCloudSettingsError.invalidCookie
            }
            Self.log.info(
                "Qwen Cloud using manual cookie header",
                metadata: [
                    "apiCookieNames": headers.apiCookieNames.joined(separator: ","),
                    "dashboardCookieNames": headers.dashboardCookieNames.joined(separator: ","),
                    "hasSecToken": headers.hasCookie(named: "sec_token") ? "1" : "0",
                ])
            return headers
        }

        if let envCookie = QwenCloudSettingsReader.cookieHeader(environment: context.env),
           let headers = QwenCloudCookieHeaders(singleHeader: envCookie)
        {
            Self.log.info(
                "Qwen Cloud using environment cookie header",
                metadata: [
                    "apiCookieNames": headers.apiCookieNames.joined(separator: ","),
                    "dashboardCookieNames": headers.dashboardCookieNames.joined(separator: ","),
                    "hasSecToken": headers.hasCookie(named: "sec_token") ? "1" : "0",
                ])
            return headers
        }

        #if os(macOS)
        if allowCached,
           let cached = CookieHeaderCache.load(provider: .qwencloud),
           let headers = QwenCloudCookieHeaders(cachedHeader: cached.cookieHeader)
        {
            Self.log.info(
                "Qwen Cloud using cached browser cookie header",
                metadata: [
                    "source": cached.sourceLabel,
                    "apiCookieNames": headers.apiCookieNames.joined(separator: ","),
                    "dashboardCookieNames": headers.dashboardCookieNames.joined(separator: ","),
                    "hasSecToken": headers.hasCookie(named: "sec_token") ? "1" : "0",
                ])
            return headers
        }

        do {
            var importLog: [String] = []
            let session = try QwenCloudCookieImport.importSession(
                browserDetection: context.browserDetection,
                logger: { importLog.append($0) })
            let rawCookieNames = session.cookies.map(\.name).filter { !$0.isEmpty }.uniquedSorted()
            guard let headers = QwenCloudCookieHeader.headers(
                from: session.cookies,
                environment: context.env)
            else {
                Self.log.warning(
                    "Qwen Cloud browser cookie header was empty",
                    metadata: [
                        "source": session.sourceLabel,
                        "rawCookieNames": rawCookieNames.joined(separator: ","),
                    ])
                throw QwenCloudSettingsError.missingCookie(
                    details: "No Qwen Cloud browser cookies were available after import.")
            }
            CookieHeaderCache.store(
                provider: .qwencloud,
                cookieHeader: headers.cacheCookieHeader,
                sourceLabel: session.sourceLabel)
            Self.log.info(
                "Qwen Cloud imported browser cookies",
                metadata: [
                    "source": session.sourceLabel,
                    "rawCookieNames": rawCookieNames.joined(separator: ","),
                    "apiCookieNames": headers.apiCookieNames.joined(separator: ","),
                    "dashboardCookieNames": headers.dashboardCookieNames.joined(separator: ","),
                    "hasSecToken": headers.hasCookie(named: "sec_token") ? "1" : "0",
                    "importLogLines": "\(importLog.count)",
                ])
            return headers
        } catch {
            Self.log.warning(
                "Qwen Cloud cookie resolution failed",
                metadata: ["error": error.localizedDescription])
            throw QwenCloudSettingsError.missingCookie(details: Self.missingCookieDetails(from: error))
        }
        #else
        throw QwenCloudSettingsError.missingCookie()
        #endif
    }

    private static func missingCookieDetails(from error: Error) -> String? {
        if case let AlibabaCodingPlanSettingsError.missingCookie(details) = error {
            return details
        }
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }
}

extension QwenCloudUsageError {
    fileprivate var isCredentialFailure: Bool {
        switch self {
        case .loginRequired, .invalidCredentials:
            true
        case .apiError, .networkError, .parseFailed:
            false
        }
    }
}

extension [String] {
    fileprivate func uniquedSorted() -> [String] {
        Array(Set(self)).sorted()
    }
}
