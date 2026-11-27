import Foundation

public struct VertexAIProviderSettings: Sendable, Equatable, Hashable {
    public var projectIDOverride: String?
    public var regionFilter: String?
    public var modelFilter: String?
    public var primaryBarMetric: VertexAIPrimaryBarMetric
    public var telemetryCostSource: VertexAITelemetryCostSource
    public var allowClaudeFallback: Bool
    public var estimateCloudCost: Bool

    public init(
        projectIDOverride: String? = nil,
        regionFilter: String? = nil,
        modelFilter: String? = nil,
        primaryBarMetric: VertexAIPrimaryBarMetric = .auto,
        telemetryCostSource: VertexAITelemetryCostSource = .auto,
        allowClaudeFallback: Bool = false,
        estimateCloudCost: Bool = false)
    {
        self.projectIDOverride = Self.normalizedOptionalString(projectIDOverride)
        self.regionFilter = Self.normalizedRegionFilter(regionFilter)
        self.modelFilter = Self.normalizedOptionalString(modelFilter)
        self.primaryBarMetric = primaryBarMetric
        self.telemetryCostSource = telemetryCostSource
        self.allowClaudeFallback = allowClaudeFallback
        self.estimateCloudCost = estimateCloudCost
    }

    private static func normalizedOptionalString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func normalizedRegionFilter(_ value: String?) -> String? {
        guard let normalized = normalizedOptionalString(value) else { return nil }
        if normalized.caseInsensitiveCompare(VertexAIRegionFilterOption.all.rawValue) == .orderedSame {
            return nil
        }
        return normalized
    }
}

public enum VertexAIProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.vertexai
    public typealias Section = VertexAIProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias VertexAIProviderSettings = CodexBarCore.VertexAIProviderSettings

    public var vertexai: VertexAIProviderSettings? {
        self[VertexAIProviderSettingsKey.self]
    }

    public static func make(vertexai: VertexAIProviderSettings?) -> Self {
        self.make(vertexai, for: VertexAIProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func vertexai(_ section: VertexAIProviderSettings) -> Self {
        Self(section, for: VertexAIProviderSettingsKey.self)
    }
}
