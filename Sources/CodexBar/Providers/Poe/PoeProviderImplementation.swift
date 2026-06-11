import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct PoeProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .poe
    let supportsLoginFlow: Bool = true

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { context in
            let hasConnectedOAuth = !(context.settings.providerConfig(for: .poe)?.sanitizedSecretKey?.isEmpty ?? true)
            if hasConnectedOAuth {
                return "oauth"
            }
            let source = context.store.sourceLabel(for: .poe)
            return source.isEmpty ? "api" : source
        }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.providerConfig(for: .poe)?.sanitizedSecretKey
    }

    @MainActor
    func settingsActions(context: ProviderSettingsContext) -> [ProviderSettingsActionsDescriptor] {
        let config = context.settings.providerConfig(for: .poe)
        let hasConnectedOAuth = !(config?.sanitizedSecretKey?.isEmpty ?? true)
        let expiryState = self.oauthExpiryState(config: config)
        let subtitle = switch expiryState {
        case .connectedNoExpiry:
            "Connected via Poe OAuth. OAuth key is preferred over manual API key."
        case let .connected(expiresIn):
            "Connected via Poe OAuth. Key expires in \(expiresIn)."
        case let .expiringSoon(expiresIn):
            "Poe OAuth key expires soon (\(expiresIn)). Reconnect now to avoid interruptions."
        case .expired:
            "Poe OAuth key expired. Click Reconnect Poe to continue fetching usage."
        case .notConnected:
            "Connect with Poe OAuth to get an API key automatically."
        }
        let connectTitle = if hasConnectedOAuth {
            expiryState == .expired ? "Reconnect Poe (Required)" : "Reconnect Poe"
        } else {
            "Connect Poe"
        }

        return [
            ProviderSettingsActionsDescriptor(
                id: "poe-oauth",
                title: "Poe OAuth",
                subtitle: subtitle,
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "poe-oauth-connect",
                        title: connectTitle,
                        style: .bordered,
                        isVisible: nil,
                        perform: {
                            await context.runLoginFlow()
                        }),
                    ProviderSettingsActionDescriptor(
                        id: "poe-oauth-disconnect",
                        title: "Disconnect",
                        style: .link,
                        isVisible: { hasConnectedOAuth },
                        perform: {
                            context.settings.updateProviderConfig(provider: .poe) { entry in
                                entry.secretKey = nil
                                entry.workspaceID = nil
                            }
                            await context.store.refresh()
                        }),
                ],
                isVisible: nil),
        ]
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        ProviderTokenResolver.poeToken(environment: context.environment) != nil
    }

    @MainActor
    func runLoginFlow(context: ProviderLoginContext) async -> Bool {
        await context.controller.runPoeLoginFlow()
        return false
    }

    private enum OAuthExpiryState: Equatable {
        case notConnected
        case connectedNoExpiry
        case connected(expiresIn: String)
        case expiringSoon(expiresIn: String)
        case expired
    }

    private func oauthExpiryState(config: ProviderConfig?) -> OAuthExpiryState {
        guard let oauthKey = config?.sanitizedSecretKey, !oauthKey.isEmpty else {
            return .notConnected
        }
        guard let expiryRaw = config?.sanitizedWorkspaceID, let expiryTs = TimeInterval(expiryRaw) else {
            return .connectedNoExpiry
        }
        let secondsLeft = Int(expiryTs - Date().timeIntervalSince1970)
        if secondsLeft <= 0 { return .expired }
        if secondsLeft <= 86400 {
            return .expiringSoon(expiresIn: Self.relativeDuration(secondsLeft))
        }
        return .connected(expiresIn: Self.relativeDuration(secondsLeft))
    }

    private static func relativeDuration(_ seconds: Int) -> String {
        if seconds < 3600 { return "\(max(1, seconds / 60))m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}
