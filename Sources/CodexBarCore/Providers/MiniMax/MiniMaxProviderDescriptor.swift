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
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [MiniMaxCodingPlanFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "minimax",
                aliases: ["mini-max"],
                versionDetector: nil))
    }
}

struct MiniMaxCodingPlanFetchStrategy: ProviderFetchStrategy {
    let id: String = "minimax.web"
    let kind: ProviderFetchKind = .web
    private static let log = CodexBarLog.logger("minimax-web")

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        if Self.resolveCookieOverride(context: context) != nil {
            return true
        }
        #if os(macOS)
        return MiniMaxCookieImporter.hasSession(browserDetection: context.browserDetection)
        #else
        return false
        #endif
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        if let override = Self.resolveCookieOverride(context: context) {
            Self.log.debug("Using MiniMax cookie header from settings/env")
            let snapshot = try await MiniMaxUsageFetcher.fetchUsage(
                cookieHeader: override.cookieHeader,
                authorizationToken: override.authorizationToken,
                groupID: override.groupID)
            return self.makeResult(
                usage: snapshot.toUsageSnapshot(),
                sourceLabel: "web")
        }

        #if os(macOS)
        let sessions = (try? MiniMaxCookieImporter.importSessions(
            browserDetection: context.browserDetection)) ?? []
        guard !sessions.isEmpty else { throw MiniMaxSettingsError.missingCookie }

        let tokenLog: (String) -> Void = { msg in Self.log.debug(msg) }
        let accessTokens = MiniMaxLocalStorageImporter.importAccessTokens(
            browserDetection: context.browserDetection,
            logger: tokenLog)
        let groupIDs = MiniMaxLocalStorageImporter.importGroupIDs(
            browserDetection: context.browserDetection,
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

        var lastError: Error?
        for session in sessions {
            let tokenCandidates = tokensByLabel[session.sourceLabel] ?? []
            let groupID = groupIDByLabel[session.sourceLabel]
            let cookieToken = Self.cookieValue(named: "HERTZ-SESSION", in: session.cookieHeader)
            var attempts: [String?] = tokenCandidates.map(\.self)
            if let cookieToken, !tokenCandidates.contains(cookieToken) {
                attempts.append(cookieToken)
            }
            attempts.append(nil)
            for token in attempts {
                let tokenLabel: String = {
                    guard let token else { return "" }
                    if token == cookieToken { return " + HERTZ-SESSION bearer" }
                    return " + access token"
                }()
                Self.log.debug("Trying MiniMax cookies from \(session.sourceLabel)\(tokenLabel)")
                do {
                    let snapshot = try await MiniMaxUsageFetcher.fetchUsage(
                        cookieHeader: session.cookieHeader,
                        authorizationToken: token,
                        groupID: groupID)
                    Self.log.debug("MiniMax cookies valid from \(session.sourceLabel)")
                    return self.makeResult(
                        usage: snapshot.toUsageSnapshot(),
                        sourceLabel: "web")
                } catch {
                    lastError = error
                    if Self.shouldTryNextBrowser(for: error) {
                        if token == nil {
                            Self.log.debug("MiniMax cookies invalid from \(session.sourceLabel), trying next browser")
                        }
                        continue
                    }
                    throw error
                }
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
