import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct GroqProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .groq

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.groqSessionToken
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if GroqSettingsReader.sessionToken(environment: context.environment) != nil {
            return true
        }
        let stored = context.settings.groqSessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty { return true }
        if !context.settings.tokenAccounts(for: .groq).isEmpty { return true }
        #if os(macOS)
        return GroqCookieImporter.hasSession()
        #else
        return false
        #endif
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "groq-session-token",
                title: "Session token",
                subtitle: "Bearer JWT from console.groq.com. Open DevTools → Network, filter by \"activity\", copy the Authorization header value. Set GROQ_SESSION_TOKEN to override.",
                kind: .secure,
                placeholder: "eyJ...",
                binding: context.stringBinding(\.groqSessionToken),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
