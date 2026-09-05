import Foundation

/// Helmcode ships two dashboard tenants on the same platform: the enterprise
/// cloud at `cloud.helmcode.com` and the community cloud at `cloud.nan.builders`
/// (NaN is Helmcode's community brand). Both expose identical `/api/usage/quota`
/// and `/api/billing/credits` routes on their `cloud-api.` hosts.
public enum HelmcodeDeployment: String, CaseIterable, Sendable {
    case helmcode
    case nanBuilders

    public static let environmentKey = HelmcodeDeploymentSelection.environmentKey

    public var displayName: String {
        switch self {
        case .helmcode: "Helmcode"
        case .nanBuilders: "NaN Builders"
        }
    }

    public var dashboardHost: String {
        switch self {
        case .helmcode: "cloud.helmcode.com"
        case .nanBuilders: "cloud.nan.builders"
        }
    }

    public var apiHost: String {
        switch self {
        case .helmcode: "cloud-api.helmcode.com"
        case .nanBuilders: "cloud-api.nan.builders"
        }
    }

    public var dashboardURL: URL {
        URL(string: "https://\(self.dashboardHost)")!
    }

    public var dashboardPageURL: URL {
        self.dashboardURL.appendingPathComponent("dashboard")
    }

    public var quotaURL: URL {
        URL(string: "https://\(self.apiHost)/api/usage/quota")!
    }

    public var billingURL: URL {
        URL(string: "https://\(self.apiHost)/api/billing")!
    }

    public var creditsURL: URL {
        URL(string: "https://\(self.apiHost)/api/billing/credits")!
    }

    public var cookieDomains: [String] {
        switch self {
        case .helmcode: ["cloud-api.helmcode.com", "cloud.helmcode.com", "helmcode.com"]
        case .nanBuilders: ["cloud-api.nan.builders", "cloud.nan.builders", "nan.builders"]
        }
    }

    /// Name used in source labels and detection copy ("Helmcode Cloud" vs the brand "Helmcode").
    public var sourceLabelName: String {
        switch self {
        case .helmcode: "Helmcode Cloud"
        case .nanBuilders: "NaN Builders"
        }
    }
}

/// User-facing tenant choice: automatic detection or a pinned tenant. Stored in the provider
/// config `region` field (`auto` | `helmcode` | `nanBuilders`).
public enum HelmcodeDeploymentSelection: String, CaseIterable, Sendable {
    case auto
    case helmcode
    case nanBuilders

    public static let environmentKey = "HELMCODE_DEPLOYMENT"

    public var displayName: String {
        switch self {
        case .auto: "Automatic"
        case .helmcode: "Helmcode Cloud"
        case .nanBuilders: "NaN Builders"
        }
    }

    public var pinnedDeployment: HelmcodeDeployment? {
        switch self {
        case .auto: nil
        case .helmcode: .helmcode
        case .nanBuilders: .nanBuilders
        }
    }

    public static func resolve(environment: [String: String]) -> HelmcodeDeploymentSelection {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !raw.isEmpty
        else { return .auto }
        switch raw {
        case "nan", "nan.builders", "nanbuilders":
            return .nanBuilders
        case "helmcode", "helmcode.com":
            return .helmcode
        default:
            return HelmcodeDeploymentSelection(rawValue: raw) ?? .auto
        }
    }
}
