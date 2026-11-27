import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum CodexQuota {
    static func fetch(grant: CodexGrant, http: QuotaHTTP) async throws -> [QuotaWindow] {
        var headers = [
            "originator": CodexCLIUserAgent.originator,
            "User-Agent": CodexCLIUserAgent.make(cliVersion: nil),
        ]
        headers["ChatGPT-Account-Id"] = grant.accountID
        let data = try await http.get(
            "https://chatgpt.com/backend-api/wham/usage", token: grant.accessToken, headers: headers)
        return try self.windows(data)
    }

    private struct Window: Decodable {
        let used_percent: Decimal?
        let limit_window_seconds: Int?
        let reset_at: Double?

        func row(product: String, fallback: String) -> QuotaWindow? {
            let seconds = self.limit_window_seconds
            let period: String = switch seconds {
            case 604_800: "每周"
            case let value? where value > 0 && value.isMultiple(of: 3600): "\(value / 3600) 小时"
            case let value? where value > 0 && value.isMultiple(of: 60): "\(value / 60) 分钟"
            case let value? where value > 0: "\(value) 秒"
            default: fallback
            }
            return QuotaWindow(
                title: "\(product) · \(period)", usedPercent: self.used_percent,
                resetsAt: self.reset_at.map(Date.init(timeIntervalSince1970:)))
        }
    }

    private struct Limits: Decodable {
        let primary: Window?
        let secondary: Window?
        enum Keys: String, CodingKey { case primary_window, secondary_window }

        init(from decoder: Decoder) throws {
            let keys = try decoder.container(keyedBy: Keys.self)
            self.primary = try? keys.decode(Window.self, forKey: .primary_window)
            self.secondary = try? keys.decode(Window.self, forKey: .secondary_window)
        }

        func rows(product: String) -> [QuotaWindow] {
            [
                self.primary?.row(product: product, fallback: "主额度"),
                self.secondary?.row(product: product, fallback: "次额度"),
            ].compactMap(\.self)
        }
    }

    private struct Additional: Decodable {
        let limit_name: String?
        let metered_feature: String?
        let rate_limit: Limits?
    }

    private struct Response: Decodable {
        var windows: [QuotaWindow]
        enum Keys: String, CodingKey { case rate_limit, additional_rate_limits }

        init(from decoder: Decoder) throws {
            let root = try decoder.container(keyedBy: Keys.self)
            let limits = try? root.decode(Limits.self, forKey: .rate_limit)
            self.windows = limits?.rows(product: "Codex") ?? []
            if var extra = try? root.nestedUnkeyedContainer(forKey: .additional_rate_limits) {
                while !extra.isAtEnd {
                    let element = try extra.superDecoder()
                    guard let limit = try? Additional(from: element),
                          let name = limit.limit_name?.trimmedNonEmpty ?? limit.metered_feature?.trimmedNonEmpty
                    else { continue }
                    self.windows += limit.rate_limit?.rows(product: name) ?? []
                }
            }
        }
    }

    static func windows(_ data: Data) throws -> [QuotaWindow] {
        try JSONDecoder().decode(Response.self, from: data).windows
    }
}
