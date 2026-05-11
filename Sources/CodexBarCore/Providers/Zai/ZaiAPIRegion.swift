import Foundation

public enum ZaiAPIRegion: String, CaseIterable, Sendable {
    case global
    case bigmodelCN = "bigmodel-cn"

    private static let quotaPath = "api/monitor/usage/quota/limit"
    private static let modelUsagePath = "api/monitor/usage/model-usage"

    public var displayName: String {
        switch self {
        case .global:
            "Global (api.z.ai)"
        case .bigmodelCN:
            "BigModel CN (open.bigmodel.cn)"
        }
    }

    public var baseURLString: String {
        switch self {
        case .global:
            "https://api.z.ai"
        case .bigmodelCN:
            "https://open.bigmodel.cn"
        }
    }

    public var quotaLimitURL: URL {
        URL(string: self.baseURLString)!.appendingPathComponent(Self.quotaPath)
    }

    public var modelUsageURL: URL {
        URL(string: self.baseURLString)!.appendingPathComponent(Self.modelUsagePath)
    }
}
