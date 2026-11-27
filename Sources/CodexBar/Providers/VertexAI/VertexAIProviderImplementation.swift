import CodexBarCore
import Foundation
import SwiftUI

struct VertexAIProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .vertexai
    let supportsLoginFlow: Bool = true

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.vertexAIProjectIDOverride
        _ = settings.vertexAIRegionFilter
        _ = settings.vertexAIModelFilter
        _ = settings.vertexAIPrimaryBarMetric
        _ = settings.vertexAITelemetryCostSource
        _ = settings.vertexAIAllowClaudeFallback
        _ = settings.vertexAIEstimateCloudCost
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .vertexai(context.settings.vertexAISettingsSnapshot())
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let regionBinding = Binding<String>(
            get: {
                context.settings.vertexAIRegionFilter ?? VertexAIRegionFilterOption.all.rawValue
            },
            set: { selection in
                let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
                context.settings.vertexAIRegionFilter =
                    (trimmed.isEmpty || trimmed == VertexAIRegionFilterOption.all.rawValue) ? nil : trimmed
            })
        var regionOptions = VertexAIRegionFilterOption.allCases.map {
            ProviderSettingsPickerOption(id: $0.rawValue, title: $0.displayName, localizesTitle: false)
        }
        if let customRegion = context.settings.vertexAIRegionFilter,
           !regionOptions.contains(where: { $0.id == customRegion })
        {
            regionOptions.append(
                ProviderSettingsPickerOption(id: customRegion, title: customRegion, localizesTitle: false))
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "vertexai-primary-bar-metric",
                title: "Primary bar metric",
                subtitle: "Choose whether the main quota bar favors the highest quota %, " +
                    "rate limits (RPM/TPM/RPD), or allocation limits.",
                placement: .menuBar,
                binding: context.rawValueBinding(\.vertexAIPrimaryBarMetric, fallback: .auto),
                options: VertexAIPrimaryBarMetric.allCases.map {
                    ProviderSettingsPickerOption(id: $0.rawValue, title: $0.displayName, localizesTitle: false)
                },
                isVisible: nil,
                onChange: nil),
            ProviderSettingsPickerDescriptor(
                id: "vertexai-telemetry-cost-source",
                title: "Telemetry and cost source",
                subtitle: "Choose between Cloud Monitoring plus local Claude-on-Vertex logs, " +
                    "Cloud Monitoring only, or local Claude logs only.",
                placement: .connection,
                binding: context.rawValueBinding(\.vertexAITelemetryCostSource, fallback: .auto),
                options: VertexAITelemetryCostSource.allCases.map {
                    ProviderSettingsPickerOption(id: $0.rawValue, title: $0.displayName, localizesTitle: false)
                },
                isVisible: nil,
                onChange: nil),
            ProviderSettingsPickerDescriptor(
                id: "vertexai-region-filter",
                title: "Region filter",
                subtitle: "Optional. Scope Cloud Monitoring quotas and serving telemetry to a specific GCP location.",
                placement: .connection,
                binding: regionBinding,
                options: regionOptions,
                isVisible: nil,
                onChange: nil),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "vertexai-project-id-override",
                title: "GCP Project ID override",
                subtitle: "Optional. Overrides gcloud config_default and environment project variables.",
                footerText: nil,
                kind: .plain,
                placeholder: "gcloud config_default / env",
                binding: Binding(
                    get: { context.settings.vertexAIProjectIDOverride ?? "" },
                    set: { context.settings.vertexAIProjectIDOverride = $0 }),
                actions: [],
                isVisible: nil),
            ProviderSettingsFieldDescriptor(
                id: "vertexai-model-filter",
                title: "Base model filter",
                subtitle: "Optional. Filter Cloud Monitoring quotas and serving telemetry by model " +
                    "(for example claude-sonnet-4-6 or gemini-2.5-pro).",
                footerText: nil,
                kind: .plain,
                placeholder: "All models",
                binding: Binding(
                    get: { context.settings.vertexAIModelFilter ?? "" },
                    set: { context.settings.vertexAIModelFilter = $0 }),
                actions: [],
                isVisible: nil),
        ]
    }

    @MainActor
    func settingsToggles(context: ProviderSettingsContext) -> [ProviderSettingsToggleDescriptor] {
        [
            ProviderSettingsToggleDescriptor(
                id: "vertexai-allow-claude-fallback",
                title: "Include all Claude logs fallback",
                subtitle: "Optional. Include non-Vertex Claude Code logs from ~/.claude/projects when computing " +
                    "Vertex AI token and cost breakdowns.",
                binding: context.binding(\.vertexAIAllowClaudeFallback),
                statusText: nil,
                actions: [],
                isVisible: nil,
                onChange: nil,
                onAppDidBecomeActive: nil,
                onAppearWhenEnabled: nil),
            ProviderSettingsToggleDescriptor(
                id: "vertexai-estimate-cloud-cost",
                title: "Estimate USD cost from Cloud Monitoring tokens",
                subtitle: "Optional. Estimate USD spend from Cloud Monitoring token_count using public API " +
                    "list prices for shared pay-as-you-go traffic.",
                binding: context.binding(\.vertexAIEstimateCloudCost),
                statusText: nil,
                actions: [],
                isVisible: nil,
                onChange: nil,
                onAppDidBecomeActive: nil,
                onAppearWhenEnabled: nil),
        ]
    }

    @MainActor
    func runLoginFlow(context: ProviderLoginContext) async -> Bool {
        await context.controller.runVertexAILoginFlow()
        return false
    }
}
