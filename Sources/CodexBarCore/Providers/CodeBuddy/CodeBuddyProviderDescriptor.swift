import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum CodeBuddyProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .codebuddy,
            metadata: ProviderMetadata(
                id: .codebuddy,
                displayName: "CodeBuddy",
                sessionLabel: "Credits",
                weeklyLabel: "Cycle",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: true,
                creditsHint: "Credits used this billing cycle",
                toggleTitle: "Show CodeBuddy usage",
                cliName: "codebuddy",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://tencent.sso.codebuddy.cn/profile/usage",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .codebuddy,
                iconResourceName: "ProviderIcon-codebuddy",
                color: ProviderColor(red: 0 / 255, green: 120 / 255, blue: 215 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "CodeBuddy cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [CodeBuddyWebFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "codebuddy",
                aliases: ["cb"],
                versionDetector: nil))
    }
}

struct CodeBuddyWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "codebuddy.web"
    let kind: ProviderFetchKind = .web
    private static let log = CodexBarLog.logger(LogCategories.codeBuddyWeb)

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        // Check if we have manual cookie override
        if CodeBuddyCookieHeader.resolveCookieOverride(context: context) != nil {
            // Also need enterprise ID to be available
            if context.settings?.codebuddy?.enterpriseID != nil {
                return true
            }
            if CodeBuddySettingsReader.enterpriseID(environment: context.env) != nil {
                return true
            }
        }

        #if os(macOS)
        if context.settings?.codebuddy?.cookieSource != .off {
            // Need both cookies and enterprise ID
            if CodeBuddyCookieImporter.hasSession() {
                if context.settings?.codebuddy?.enterpriseID != nil {
                    return true
                }
                if CodeBuddySettingsReader.enterpriseID(environment: context.env) != nil {
                    return true
                }
            }
        }
        #endif

        return false
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let (cookieHeader, enterpriseID) = try self.resolveCookiesAndEnterpriseID(context: context)

        let snapshot = try await CodeBuddyUsageFetcher.fetchUsage(
            cookieHeader: cookieHeader,
            enterpriseID: enterpriseID)

        // Also fetch daily usage (non-blocking, failure doesn't affect main result)
        var dailyUsage: [CodeBuddyDailyUsageEntry]?
        do {
            dailyUsage = try await CodeBuddyUsageFetcher.fetchDailyUsage(
                cookieHeader: cookieHeader,
                enterpriseID: enterpriseID)
            Self.log.info("CodeBuddy daily usage fetched: \(dailyUsage?.count ?? 0) entries")
        } catch {
            Self.log.error("CodeBuddy daily usage fetch failed: \(error.localizedDescription)")
        }

        let result = self.makeResult(
            usage: snapshot.toUsageSnapshot(),
            codeBuddyDailyUsage: dailyUsage,
            sourceLabel: "web")
        Self.log.info("CodeBuddy fetch result created: dailyUsage in result = \(result.codeBuddyDailyUsage?.count ?? -1)")
        return result
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        if case CodeBuddyAPIError.missingCookies = error { return false }
        if case CodeBuddyAPIError.missingEnterpriseID = error { return false }
        if case CodeBuddyAPIError.invalidCookies = error { return false }
        return true
    }

    private func resolveCookiesAndEnterpriseID(context: ProviderFetchContext) throws -> (String, String) {
        var cookieHeader: String?
        var enterpriseID: String?

        // Check manual override first
        if let override = CodeBuddyCookieHeader.resolveCookieOverride(context: context) {
            cookieHeader = override.cookieHeader
            enterpriseID = override.enterpriseID
        }

        // Try browser cookie import
        #if os(macOS)
        if cookieHeader == nil, context.settings?.codebuddy?.cookieSource != .off {
            do {
                let session = try CodeBuddyCookieImporter.importSession()
                cookieHeader = session.cookieHeader
            } catch {
                // No browser cookies found
            }
        }
        #endif

        // Check settings for enterprise ID
        if enterpriseID == nil {
            enterpriseID = context.settings?.codebuddy?.enterpriseID
        }

        // Check environment for enterprise ID
        if enterpriseID == nil {
            enterpriseID = CodeBuddySettingsReader.enterpriseID(environment: context.env)
        }

        guard let finalCookieHeader = cookieHeader, !finalCookieHeader.isEmpty else {
            throw CodeBuddyAPIError.missingCookies
        }

        guard let finalEnterpriseID = enterpriseID, !finalEnterpriseID.isEmpty else {
            throw CodeBuddyAPIError.missingEnterpriseID
        }

        return (finalCookieHeader, finalEnterpriseID)
    }
}
