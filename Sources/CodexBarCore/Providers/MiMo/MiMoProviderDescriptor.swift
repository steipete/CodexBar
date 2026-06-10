import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum MiMoProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .mimo,
            metadata: ProviderMetadata(
                id: .mimo,
                displayName: "Xiaomi MiMo",
                sessionLabel: "Credits",
                weeklyLabel: "Window",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: true,
                creditsHint: "Token plan credits usage.",
                toggleTitle: "Show Xiaomi MiMo token plan & balance",
                cliName: "mimo",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.mimoCookieImportOrder,
                dashboardURL: "https://platform.xiaomimimo.com/#/console/balance",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .mimo,
                iconResourceName: "ProviderIcon-mimo",
                color: ProviderColor(red: 1.0, green: 105 / 255, blue: 0)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Xiaomi MiMo cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [MiMoWebFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "mimo",
                aliases: ["xiaomi-mimo"],
                versionDetector: nil))
    }
}

struct MiMoWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "mimo.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.mimo?.cookieSource != .off else { return false }
        if context.settings?.mimo?.cookieSource == .manual {
            return Self.resolveManualCookieHeader(context: context) != nil
        }
        // Fetch resolves the session so missing-cookie and browser-permission errors stay actionable.
        return true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard context.settings?.mimo?.cookieSource != .off else {
            throw MiMoSettingsError.missingCookie()
        }
        if context.settings?.mimo?.cookieSource == .manual {
            guard let manualCookie = Self.resolveManualCookieHeader(context: context) else {
                throw MiMoSettingsError.invalidCookie
            }
            let snapshot = try await MiMoUsageFetcher.fetchUsage(
                cookieHeader: manualCookie,
                environment: context.env)
            return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: "web")
        }
        if let manualCookie = Self.resolveManualCookieHeader(context: context) {
            let snapshot = try await MiMoUsageFetcher.fetchUsage(
                cookieHeader: manualCookie,
                environment: context.env)
            return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: "web")
        }

        #if os(macOS)
        var lastError: Error?

        if let cached = CookieHeaderCache.load(provider: .mimo),
           let cachedHeader = MiMoCookieHeader.normalizedHeader(from: cached.cookieHeader)
        {
            do {
                let snapshot = try await MiMoUsageFetcher.fetchUsage(
                    cookieHeader: cachedHeader,
                    environment: context.env)
                return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: "web")
            } catch {
                guard Self.shouldRetryNextSession(for: error) else {
                    throw error
                }
                CookieHeaderCache.clear(provider: .mimo)
                lastError = error
            }
        }

        let sessions = try MiMoCookieImporter.importSessions(browserDetection: context.browserDetection)
        guard !sessions.isEmpty else {
            if let lastError { throw lastError }
            throw MiMoSettingsError.missingCookie()
        }

        for session in sessions {
            do {
                let snapshot = try await MiMoUsageFetcher.fetchUsage(
                    cookieHeader: session.cookieHeader,
                    environment: context.env)
                CookieHeaderCache.store(
                    provider: .mimo,
                    cookieHeader: session.cookieHeader,
                    sourceLabel: session.sourceLabel)
                return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: "web")
            } catch {
                guard Self.shouldRetryNextSession(for: error) else {
                    throw error
                }
                lastError = error
                continue
            }
        }

        if let lastError { throw lastError }
        throw MiMoSettingsError.missingCookie()
        #else
        throw MiMoSettingsError.missingCookie()
        #endif
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func resolveManualCookieHeader(context: ProviderFetchContext) -> String? {
        guard context.settings?.mimo?.cookieSource == .manual else { return nil }
        return MiMoCookieHeader.normalizedHeader(from: context.settings?.mimo?.manualCookieHeader)
    }

    private static func shouldRetryNextSession(for error: Error) -> Bool {
        if error is DecodingError {
            return true
        }
        guard let mimoError = error as? MiMoUsageError else {
            return false
        }
        switch mimoError {
        case .invalidCredentials, .loginRequired, .parseFailed:
            return true
        case .networkError:
            return false
        }
    }
}
