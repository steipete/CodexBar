import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum CommandCodeProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .commandcode,
            metadata: ProviderMetadata(
                id: .commandcode,
                displayName: "Command Code",
                sessionLabel: "Monthly credits",
                weeklyLabel: "Monthly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: true,
                creditsHint: "Monthly USD credits from Command Code billing.",
                toggleTitle: "Show Command Code usage",
                cliName: "commandcode",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://commandcode.ai/studio",
                subscriptionDashboardURL: "https://commandcode.ai/sixhobbits/settings/billing",
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .commandcode,
                iconResourceName: "ProviderIcon-commandcode",
                color: ProviderColor(red: 0 / 255, green: 0 / 255, blue: 0 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Command Code cost summary is not yet supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [CommandCodeWebFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "commandcode",
                aliases: ["command-code"],
                versionDetector: nil))
    }
}

struct CommandCodeWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "commandcode.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.commandcode?.cookieSource != .off else { return false }
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        #if os(macOS)
        let cookieHeader: String
        let sourceLabel: String
        if let manual = Self.manualCookieHeader(from: context) {
            cookieHeader = manual
            sourceLabel = "manual"
        } else {
            let session: CommandCodeCookieImporter.SessionInfo
            do {
                session = try CommandCodeCookieImporter.importSession()
            } catch {
                throw CommandCodeUsageError.missingCredentials
            }
            guard !session.cookies.isEmpty else {
                throw CommandCodeUsageError.missingCredentials
            }
            cookieHeader = session.cookieHeader
            sourceLabel = session.sourceLabel
        }
        let snapshot = try await CommandCodeUsageFetcher.fetchUsage(cookieHeader: cookieHeader)
        return self.makeResult(
            usage: snapshot.toUsageSnapshot(),
            sourceLabel: sourceLabel)
        #else
        throw CommandCodeUsageError.missingCredentials
        #endif
    }

    private static func manualCookieHeader(from context: ProviderFetchContext) -> String? {
        guard context.settings?.commandcode?.cookieSource == .manual else { return nil }
        return CookieHeaderNormalizer.normalize(context.settings?.commandcode?.manualCookieHeader)
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
