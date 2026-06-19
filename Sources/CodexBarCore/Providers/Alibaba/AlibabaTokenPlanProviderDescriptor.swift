import Foundation

#if os(macOS)
import SweetCookieKit
#endif

public enum AlibabaTokenPlanProviderDescriptor {
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
            id: .alibabatokenplan,
            metadata: ProviderMetadata(
                id: .alibabatokenplan,
                displayName: "Alibaba Token Plan",
                sessionLabel: "Credits",
                weeklyLabel: "Usage",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Alibaba Token Plan usage",
                cliName: "alibaba-token-plan",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: browserOrder,
                dashboardURL: AlibabaTokenPlanUsageFetcher.dashboardURL.absoluteString,
                statusPageURL: nil,
                statusLinkURL: "https://status.aliyun.com"),
            branding: ProviderBranding(
                iconStyle: .alibaba,
                iconResourceName: "ProviderIcon-alibaba",
                color: ProviderColor(red: 1.0, green: 106 / 255, blue: 0)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Alibaba Token Plan cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "alibaba-token-plan",
                aliases: ["alibaba-token", "bailian-token-plan"],
                versionDetector: nil))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        guard context.settings?.alibabaTokenPlan?.cookieSource != .off else { return [] }
        switch context.sourceMode {
        case .auto, .web:
            return [AlibabaTokenPlanWebFetchStrategy()]
        case .api, .cli, .oauth:
            return []
        }
    }
}

struct AlibabaTokenPlanWebFetchStrategy: ProviderFetchStrategy {
    private static let log = CodexBarLog.logger("alibaba-token-plan")

    let id: String = "alibaba-token-plan.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.alibabaTokenPlan?.cookieSource != .off else { return false }

        if AlibabaTokenPlanSettingsReader.cookieHeader(environment: context.env) != nil {
            return true
        }

        if let settings = context.settings?.alibabaTokenPlan,
           settings.cookieSource == .manual
        {
            return CookieHeaderNormalizer.normalize(settings.manualCookieHeader) != nil
        }

        #if os(macOS)
        if let cached = CookieHeaderCache.load(provider: .alibabatokenplan),
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
        let cookieSource = context.settings?.alibabaTokenPlan?.cookieSource ?? .auto
        let cookieHeaders = try Self.resolveCookieHeaders(context: context, allowCached: true)
        do {
            let usage = try await AlibabaTokenPlanUsageFetcher.fetchUsage(
                apiCookieHeader: cookieHeaders.apiCookieHeader,
                dashboardCookieHeader: cookieHeaders.dashboardCookieHeader,
                environment: context.env)
            return self.makeResult(usage: usage.toUsageSnapshot(), sourceLabel: "web")
        } catch let error as AlibabaTokenPlanUsageError
            where error.isCredentialFailure && cookieSource != .manual
        {
            #if os(macOS)
            CookieHeaderCache.clear(provider: .alibabatokenplan)
            let refreshedHeaders = try Self.resolveCookieHeaders(context: context, allowCached: false)
            let usage = try await AlibabaTokenPlanUsageFetcher.fetchUsage(
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
        allowCached: Bool) throws -> AlibabaTokenPlanCookieHeaders
    {
        if let settings = context.settings?.alibabaTokenPlan,
           settings.cookieSource == .manual
        {
            guard let headers = AlibabaTokenPlanCookieHeaders(singleHeader: settings.manualCookieHeader) else {
                self.log.warning("Alibaba Token Plan manual cookie header is invalid")
                throw AlibabaTokenPlanSettingsError.invalidCookie
            }
            Self.log.info(
                "Alibaba Token Plan using manual cookie header",
                metadata: [
                    "apiCookieNames": headers.apiCookieNames.joined(separator: ","),
                    "dashboardCookieNames": headers.dashboardCookieNames.joined(separator: ","),
                    "hasSecToken": headers.hasCookie(named: "sec_token") ? "1" : "0",
                ])
            return headers
        }

        if let envCookie = AlibabaTokenPlanSettingsReader.cookieHeader(environment: context.env),
           let headers = AlibabaTokenPlanCookieHeaders(singleHeader: envCookie)
        {
            Self.log.info(
                "Alibaba Token Plan using environment cookie header",
                metadata: [
                    "apiCookieNames": headers.apiCookieNames.joined(separator: ","),
                    "dashboardCookieNames": headers.dashboardCookieNames.joined(separator: ","),
                    "hasSecToken": headers.hasCookie(named: "sec_token") ? "1" : "0",
                ])
            return headers
        }

        #if os(macOS)
        if allowCached,
           let cached = CookieHeaderCache.load(provider: .alibabatokenplan),
           let headers = AlibabaTokenPlanCookieHeaders(cachedHeader: cached.cookieHeader)
        {
            Self.log.info(
                "Alibaba Token Plan using cached browser cookie header",
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
            let session = try AlibabaCodingPlanCookieImporter.importSession(
                browserDetection: context.browserDetection,
                logger: { importLog.append($0) })
            let rawCookieNames = session.cookies.map(\.name).filter { !$0.isEmpty }.uniquedSorted()
            guard let headers = AlibabaTokenPlanCookieHeader.headers(
                from: session.cookies,
                environment: context.env)
            else {
                Self.log.warning(
                    "Alibaba Token Plan browser cookie header was empty",
                    metadata: [
                        "source": session.sourceLabel,
                        "rawCookieNames": rawCookieNames.joined(separator: ","),
                    ])
                throw AlibabaTokenPlanSettingsError.missingCookie(
                    details: "No Alibaba Token Plan browser cookies were available after import.")
            }
            CookieHeaderCache.store(
                provider: .alibabatokenplan,
                cookieHeader: headers.cacheCookieHeader,
                sourceLabel: session.sourceLabel)
            Self.log.info(
                "Alibaba Token Plan imported browser cookies",
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
                "Alibaba Token Plan cookie resolution failed",
                metadata: ["error": error.localizedDescription])
            throw AlibabaTokenPlanSettingsError.missingCookie(details: Self.missingCookieDetails(from: error))
        }
        #else
        throw AlibabaTokenPlanSettingsError.missingCookie()
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

extension [String] {
    fileprivate func uniquedSorted() -> [String] {
        Array(Set(self)).sorted()
    }
}

extension AlibabaTokenPlanUsageError {
    fileprivate var isCredentialFailure: Bool {
        switch self {
        case .loginRequired, .invalidCredentials:
            true
        case .apiError, .networkError, .parseFailed:
            false
        }
    }
}
