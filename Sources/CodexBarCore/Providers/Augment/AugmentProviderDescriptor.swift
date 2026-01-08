import CodexBarMacroSupport
import Foundation

#if os(macOS)
import SweetCookieKit
#endif

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum AugmentProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        #if os(macOS)
        // Custom browser order that includes Chrome Beta and other variants
        // to support users running beta/canary versions
        let browserOrder: BrowserCookieImportOrder = [
            .safari,
            .chrome,
            .chromeBeta, // Added for Chrome Beta support
            .chromeCanary, // Added for Chrome Canary support
            .edge,
            .edgeBeta,
            .brave,
            .arc,
            .arcBeta,
            .firefox,
        ]
        #else
        let browserOrder: BrowserCookieImportOrder? = nil
        #endif

        return ProviderDescriptor(
            id: .augment,
            metadata: ProviderMetadata(
                id: .augment,
                displayName: "Augment",
                sessionLabel: "Credits",
                weeklyLabel: "Usage",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: true,
                creditsHint: "Augment Code credits for AI-powered coding assistance.",
                toggleTitle: "Show Augment usage",
                cliName: "augment",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: browserOrder,
                dashboardURL: "https://app.augmentcode.com/account/subscription",
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .augment,
                iconResourceName: "ProviderIcon-augment",
                color: ProviderColor(red: 99 / 255, green: 102 / 255, blue: 241 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Augment cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli],
                pipeline: ProviderFetchPipeline(resolveStrategies: { context in
                    var strategies: [any ProviderFetchStrategy] = []
                    // Try CLI first (no browser prompts!)
                    strategies.append(AugmentCLIFetchStrategy())
                    // Fallback to web (browser cookies)
                    strategies.append(AugmentStatusFetchStrategy())
                    return strategies
                })),
            cli: ProviderCLIConfig(
                name: "augment",
                versionDetector: nil))
    }
}

struct AugmentCLIFetchStrategy: ProviderFetchStrategy {
    let id: String = "augment.cli"
    let kind: ProviderFetchKind = .cli

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        // Check if auggie CLI is installed
        let env = ProcessInfo.processInfo.environment
        let loginPATH = LoginShellPathCache.shared.current
        return BinaryLocator.resolveAuggieBinary(env: env, loginPATH: loginPATH) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let probe = AuggieCLIProbe()
        let snap = try await probe.fetch()
        return self.makeResult(
            usage: snap.toUsageSnapshot(),
            sourceLabel: "cli")
    }

    func shouldFallback(on error: Error, context _: ProviderFetchContext) -> Bool {
        // Fallback to web if CLI fails (not authenticated, etc.)
        if let cliError = error as? AuggieCLIError {
            switch cliError {
            case .notAuthenticated, .noOutput:
                return true
            case .parseError:
                return false  // Don't fallback on parse errors - something is wrong
            }
        }
        return true
    }
}

struct AugmentStatusFetchStrategy: ProviderFetchStrategy {
    let id: String = "augment.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.augment?.cookieSource != .off else { return false }
        return true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let probe = AugmentStatusProbe()
        let manual = Self.manualCookieHeader(from: context)
        let logger: ((String) -> Void)? = context.verbose ? { msg in print("[augment] \(msg)") } : nil
        let snap = try await probe.fetch(cookieHeaderOverride: manual, logger: logger)
        return self.makeResult(
            usage: snap.toUsageSnapshot(),
            sourceLabel: "web")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func manualCookieHeader(from context: ProviderFetchContext) -> String? {
        guard context.settings?.augment?.cookieSource == .manual else { return nil }
        return CookieHeaderNormalizer.normalize(context.settings?.augment?.manualCookieHeader)
    }
}
