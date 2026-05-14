import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct KiloProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .kilo

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.kiloUsageDataSource
        _ = settings.kiloExtrasEnabled
        _ = settings.kiloAPIToken
    }

    @MainActor
    func isAvailable(context _: ProviderAvailabilityContext) -> Bool {
        // Keep availability permissive to avoid main-thread auth-file I/O while still showing Kilo for auth.json-only
        // setups. Fetch-time auth resolution remains authoritative (env first, then auth file fallback).
        true
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .kilo(context.settings.kiloSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func defaultSourceLabel(context: ProviderSourceLabelContext) -> String? {
        context.settings.kiloUsageDataSource.rawValue
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        switch context.settings.kiloUsageDataSource {
        case .auto: .auto
        case .api: .api
        case .cli: .cli
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let usageBinding = Binding(
            get: { context.settings.kiloUsageDataSource.rawValue },
            set: { raw in
                context.settings.kiloUsageDataSource = KiloUsageDataSource(rawValue: raw) ?? .auto
            })
        let usageOptions = KiloUsageDataSource.allCases.map {
            ProviderSettingsPickerOption(id: $0.rawValue, title: $0.displayName)
        }
        return [
            ProviderSettingsPickerDescriptor(
                id: "kilo-usage-source",
                title: "Usage source",
                subtitle: "Auto uses API first, then falls back to CLI on auth failures.",
                binding: usageBinding,
                options: usageOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    guard context.settings.kiloUsageDataSource == .auto else { return nil }
                    let label = context.store.sourceLabel(for: .kilo)
                    return label == "auto" ? nil : LocalizedProviderText.sourceLabel(label)
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "kilo-api-key",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. You can also provide KILO_API_KEY or "
                    + "~/.local/share/kilo/auth.json (kilo.access).",
                kind: .secure,
                placeholder: "kilo_...",
                binding: context.stringBinding(\.kiloAPIToken),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }

    @MainActor
    func settingsOrganizations(
        context: ProviderSettingsContext) -> ProviderSettingsOrganizationsDescriptor?
    {
        let settings = context.settings
        let store = context.store
        return ProviderSettingsOrganizationsDescriptor(
            id: "kilo-organizations",
            title: "Organizations",
            subtitle: "Show usage for organizations you belong to. Personal account is always shown.",
            entries: {
                var entries: [ProviderSettingsOrganizationsDescriptor.Entry] = [
                    .init(
                        id: "personal",
                        title: "Personal account",
                        subtitle: nil,
                        isEnabled: true,
                        isLocked: true),
                ]
                for org in settings.kiloKnownOrganizations {
                    entries.append(
                        .init(
                            id: org.id,
                            title: org.name,
                            subtitle: org.role,
                            isEnabled: settings.kiloIsOrganizationEnabled(org.id),
                            isLocked: false))
                }
                return entries
            },
            onToggle: { orgID, enabled in
                guard orgID != "personal" else { return }
                settings.setKiloOrganization(orgID, enabled: enabled)
                Task { @MainActor in
                    await ProviderInteractionContext.$current.withValue(.userInitiated) {
                        await store.refreshProvider(.kilo, allowDisabled: true)
                    }
                }
            },
            onRefresh: { [weak settings] in
                guard let settings else {
                    return .init(success: false, errorMessage: "Settings unavailable.")
                }
                let resolved: KiloResolvedBearerToken
                do {
                    resolved = try KiloBearerTokenResolver.resolve(
                        source: settings.kiloUsageDataSource,
                        apiKey: settings.configSnapshot.providerConfig(for: .kilo)?.sanitizedAPIKey)
                } catch let error as LocalizedError {
                    return .init(
                        success: false,
                        errorMessage: error.errorDescription ?? "Failed to resolve Kilo credentials.")
                } catch {
                    return .init(success: false, errorMessage: error.localizedDescription)
                }
                do {
                    let orgs = try await KiloUsageFetcher.fetchOrganizations(apiKey: resolved.token)
                    await MainActor.run {
                        settings.setKiloKnownOrganizationsPruningEnabled(orgs)
                    }
                    return .init(success: true, errorMessage: nil)
                } catch let error as LocalizedError {
                    return .init(
                        success: false,
                        errorMessage: error.errorDescription ?? "Failed to load organizations.")
                } catch {
                    return .init(success: false, errorMessage: error.localizedDescription)
                }
            },
            canRefresh: {
                switch settings.kiloUsageDataSource {
                case .api:
                    !settings.kiloAPIToken.isEmpty
                        || !(ProcessInfo.processInfo.environment[KiloSettingsReader.apiTokenKey] ?? "").isEmpty
                case .cli, .auto:
                    true
                }
            })
    }
}
