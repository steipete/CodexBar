import Foundation

public enum VertexAIPrimaryBarMetric: String, CaseIterable, Identifiable, Sendable, Codable {
    case auto
    case rateQuota = "rate-quota"
    case allocationQuota = "allocation-quota"

    public var id: String {
        self.rawValue
    }

    public var displayName: String {
        switch self {
        case .auto: "Auto (highest quota %)"
        case .rateQuota: "Rate quota % (RPM/TPM/RPD)"
        case .allocationQuota: "Allocation quota %"
        }
    }
}

public enum VertexAITelemetryCostSource: String, CaseIterable, Identifiable, Sendable, Codable {
    case auto
    case cloudMonitoringOnly = "cloud-monitoring"
    case localClaudeLogsOnly = "local-claude"

    public var id: String {
        self.rawValue
    }

    public var displayName: String {
        switch self {
        case .auto: "Auto (Cloud + Local)"
        case .cloudMonitoringOnly: "Cloud Monitoring only"
        case .localClaudeLogsOnly: "Local Claude logs only"
        }
    }
}

public enum VertexAIRegionFilterOption: String, CaseIterable, Identifiable, Sendable, Codable {
    case all
    case global
    case us
    case eu
    case usCentral1 = "us-central1"
    case usEast5 = "us-east5"
    case usEast1 = "us-east1"
    case usWest1 = "us-west1"
    case europeWest1 = "europe-west1"
    case europeWest4 = "europe-west4"
    case asiaNortheast1 = "asia-northeast1"

    public var id: String {
        self.rawValue
    }

    public var filterValue: String? {
        self == .all ? nil : self.rawValue
    }

    public var displayName: String {
        switch self {
        case .all: "All regions"
        case .global: "global"
        case .us: "us"
        case .eu: "eu"
        case .usCentral1, .usEast5, .usEast1, .usWest1, .europeWest1, .europeWest4, .asiaNortheast1:
            self.rawValue
        }
    }
}
