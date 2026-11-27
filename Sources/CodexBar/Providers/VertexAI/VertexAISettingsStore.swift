import CodexBarCore
import Foundation

extension SettingsStore {
    var vertexAIProjectIDOverride: String? {
        get { self.configSnapshot.providerConfig(for: .vertexai)?.vertexAIProjectIDOverride }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = (trimmed?.isEmpty == false) ? trimmed : nil
            self.updateProviderConfig(provider: .vertexai) { entry in
                entry.vertexAIProjectIDOverride = normalized
            }
            self.logProviderModeChange(
                provider: .vertexai,
                field: "projectIDOverride",
                value: normalized ?? "default")
        }
    }

    var vertexAIRegionFilter: String? {
        get { self.configSnapshot.providerConfig(for: .vertexai)?.vertexAIRegionFilter }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized: String? = if let trimmed,
                                         !trimmed.isEmpty,
                                         trimmed.caseInsensitiveCompare(VertexAIRegionFilterOption.all.rawValue)
                                         != .orderedSame
            {
                trimmed
            } else {
                nil
            }
            self.updateProviderConfig(provider: .vertexai) { entry in
                entry.vertexAIRegionFilter = normalized
            }
            self.logProviderModeChange(
                provider: .vertexai,
                field: "regionFilter",
                value: normalized ?? "all")
        }
    }

    var vertexAIModelFilter: String? {
        get { self.configSnapshot.providerConfig(for: .vertexai)?.vertexAIModelFilter }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = (trimmed?.isEmpty == false) ? trimmed : nil
            self.updateProviderConfig(provider: .vertexai) { entry in
                entry.vertexAIModelFilter = normalized
            }
            self.logProviderModeChange(
                provider: .vertexai,
                field: "modelFilter",
                value: normalized ?? "all")
        }
    }

    var vertexAIPrimaryBarMetric: VertexAIPrimaryBarMetric {
        get {
            self.configSnapshot.providerConfig(for: .vertexai)?.resolvedVertexAIPrimaryBarMetric ?? .auto
        }
        set {
            self.updateProviderConfig(provider: .vertexai) { entry in
                entry.vertexAIPrimaryBarMetric = newValue == .auto ? nil : newValue.rawValue
            }
            self.logProviderModeChange(
                provider: .vertexai,
                field: "primaryBarMetric",
                value: newValue.rawValue)
        }
    }

    var vertexAITelemetryCostSource: VertexAITelemetryCostSource {
        get {
            self.configSnapshot.providerConfig(for: .vertexai)?.resolvedVertexAITelemetryCostSource ?? .auto
        }
        set {
            self.updateProviderConfig(provider: .vertexai) { entry in
                entry.vertexAITelemetryCostSource = newValue == .auto ? nil : newValue.rawValue
            }
            self.logProviderModeChange(
                provider: .vertexai,
                field: "telemetryCostSource",
                value: newValue.rawValue)
        }
    }

    var vertexAIAllowClaudeFallback: Bool {
        get {
            self.configSnapshot.providerConfig(for: .vertexai)?.vertexAIAllowClaudeFallback ?? false
        }
        set {
            self.updateProviderConfig(provider: .vertexai) { entry in
                entry.vertexAIAllowClaudeFallback = newValue ? true : nil
            }
            self.logProviderModeChange(
                provider: .vertexai,
                field: "allowClaudeFallback",
                value: "\(newValue)")
        }
    }

    var vertexAIEstimateCloudCost: Bool {
        get {
            self.configSnapshot.providerConfig(for: .vertexai)?.vertexAIEstimateCloudCost ?? false
        }
        set {
            self.updateProviderConfig(provider: .vertexai) { entry in
                entry.vertexAIEstimateCloudCost = newValue ? true : nil
            }
            self.logProviderModeChange(
                provider: .vertexai,
                field: "estimateCloudCost",
                value: "\(newValue)")
        }
    }

    func vertexAISettingsSnapshot() -> VertexAIProviderSettings {
        self.configSnapshot.providerConfig(for: .vertexai)?.resolvedVertexAISettings ?? VertexAIProviderSettings()
    }
}
