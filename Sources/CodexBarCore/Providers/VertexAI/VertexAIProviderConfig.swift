import Foundation

extension ProviderConfig {
    public var vertexAIProjectIDOverride: String? {
        get { self.extensionValue(forKey: "vertexAIProjectIDOverride") }
        set { self.setExtensionValue(Self.sanitizedVertexAIOptionString(newValue), forKey: "vertexAIProjectIDOverride")
        }
    }

    public var vertexAIRegionFilter: String? {
        get { self.extensionValue(forKey: "vertexAIRegionFilter") }
        set { self.setExtensionValue(Self.sanitizedVertexAIRegionString(newValue), forKey: "vertexAIRegionFilter") }
    }

    public var vertexAIModelFilter: String? {
        get { self.extensionValue(forKey: "vertexAIModelFilter") }
        set { self.setExtensionValue(Self.sanitizedVertexAIOptionString(newValue), forKey: "vertexAIModelFilter") }
    }

    public var vertexAIPrimaryBarMetric: String? {
        get { self.extensionValue(forKey: "vertexAIPrimaryBarMetric") }
        set { self.setExtensionValue(newValue, forKey: "vertexAIPrimaryBarMetric") }
    }

    public var vertexAITelemetryCostSource: String? {
        get { self.extensionValue(forKey: "vertexAITelemetryCostSource") }
        set { self.setExtensionValue(newValue, forKey: "vertexAITelemetryCostSource") }
    }

    public var vertexAIAllowClaudeFallback: Bool? {
        get { self.extensionValue(forKey: "vertexAIAllowClaudeFallback") }
        set { self.setExtensionValue(newValue, forKey: "vertexAIAllowClaudeFallback") }
    }

    public var vertexAIEstimateCloudCost: Bool? {
        get { self.extensionValue(forKey: "vertexAIEstimateCloudCost") }
        set { self.setExtensionValue(newValue, forKey: "vertexAIEstimateCloudCost") }
    }

    public var resolvedVertexAIPrimaryBarMetric: VertexAIPrimaryBarMetric {
        self.vertexAIPrimaryBarMetric.flatMap(VertexAIPrimaryBarMetric.init(rawValue:)) ?? .auto
    }

    public var resolvedVertexAITelemetryCostSource: VertexAITelemetryCostSource {
        self.vertexAITelemetryCostSource.flatMap(VertexAITelemetryCostSource.init(rawValue:)) ?? .auto
    }

    public var resolvedVertexAISettings: VertexAIProviderSettings {
        VertexAIProviderSettings(
            projectIDOverride: self.vertexAIProjectIDOverride,
            regionFilter: self.vertexAIRegionFilter,
            modelFilter: self.vertexAIModelFilter,
            primaryBarMetric: self.resolvedVertexAIPrimaryBarMetric,
            telemetryCostSource: self.resolvedVertexAITelemetryCostSource,
            allowClaudeFallback: self.vertexAIAllowClaudeFallback ?? false,
            estimateCloudCost: self.vertexAIEstimateCloudCost ?? false)
    }

    private static func sanitizedVertexAIOptionString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func sanitizedVertexAIRegionString(_ value: String?) -> String? {
        guard let sanitized = sanitizedVertexAIOptionString(value) else { return nil }
        if sanitized.caseInsensitiveCompare(VertexAIRegionFilterOption.all.rawValue) == .orderedSame {
            return nil
        }
        return sanitized
    }
}
