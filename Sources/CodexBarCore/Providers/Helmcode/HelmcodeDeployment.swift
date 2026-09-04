import Foundation

/// Helmcode ships two dashboard tenants on the same platform: the enterprise
/// cloud at `cloud.helmcode.com` and the community cloud at `cloud.nan.builders`
/// (NaN is Helmcode's community brand). Both expose identical `/api/usage/quota`
/// and `/api/billing/credits` routes on their `cloud-api.` hosts.
public enum HelmcodeDeployment: String, CaseIterable, Sendable {
    case helmcode
    case nanBuilders

    public static let environmentKey = "HELMCODE_DEPLOYMENT"

    public static func resolve(environment: [String: String]) -> HelmcodeDeployment {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !raw.isEmpty
        else { return .helmcode }
        switch raw {
        case "nan", "nan.builders", "nanbuilders":
            return .nanBuilders
        case "helmcode", "helmcode.com":
            return .helmcode
        default:
            return HelmcodeDeployment(rawValue: raw) ?? .helmcode
        }
    }

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

    public var dashboardCreditsURL: URL {
        self.dashboardURL.appendingPathComponent("credits")
    }

    public var quotaURL: URL {
        URL(string: "https://\(self.apiHost)/api/usage/quota")!
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
}
