import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct FirmwareProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .firmware

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.firmwareAPIToken
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if FirmwareSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        context.settings.ensureFirmwareAPITokenLoaded()
        return !context.settings.firmwareAPIToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "firmware-api-key",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. Paste the key from the Firmware dashboard.",
                kind: .secure,
                placeholder: "Paste key...",
                binding: context.stringBinding(\.firmwareAPIToken),
                actions: [],
                isVisible: nil,
                onActivate: { context.settings.ensureFirmwareAPITokenLoaded() }),
        ]
    }
}
