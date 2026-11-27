import Foundation

enum KimiQuota {
    /// Decode lanes independently. In particular, malformed optional membership data cannot hide the core quotas.
    private struct Response: Decodable {
        let session: KimiRatioPool?
        let weekly: KimiRatioPool?
        let monthly: KimiRatioPool?
        let sessionCount: KimiUsageDetail?
        let weeklyCount: KimiUsageDetail?

        enum Keys: String, CodingKey {
            case usages, usage, limits
            case session = "limit_5h"
            case weekly = "limit_7d"
            case monthly = "limit_month_total"
        }

        init(from decoder: Decoder) throws {
            let root = try decoder.container(keyedBy: Keys.self)
            let pools = try? root.nestedContainer(keyedBy: Keys.self, forKey: .usages)
            self.session = try? pools?.decode(KimiRatioPool.self, forKey: .session)
            self.weekly = try? pools?.decode(KimiRatioPool.self, forKey: .weekly)
            self.monthly = try? pools?.decode(KimiRatioPool.self, forKey: .monthly)
            self.weeklyCount = try? root.decode(KimiUsageDetail.self, forKey: .usage)
            var sessionCount: KimiUsageDetail?
            if var limits = try? root.nestedUnkeyedContainer(forKey: .limits) {
                while !limits.isAtEnd {
                    let element = try limits.superDecoder()
                    if let limit = try? KimiRateLimit(from: element), limit.window.durationMinutes == 300 {
                        sessionCount = limit.detail
                        break
                    }
                }
            }
            self.sessionCount = sessionCount
        }
    }

    static func windows(_ data: Data) throws -> [QuotaWindow] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        return [
            self.window("5 小时", pool: response.session, count: response.sessionCount),
            self.window("每周", pool: response.weekly, count: response.weeklyCount),
            self.window("每月", pool: response.monthly, count: nil),
        ].compactMap(\.self)
    }

    private static func window(_ title: String, pool: KimiRatioPool?, count: KimiUsageDetail?) -> QuotaWindow? {
        let counted = self.countWindow(title, count: count)
        guard let raw = pool?.usedRatio, raw.isFinite, raw >= 0, let ratio = Decimal(string: String(raw))
        else { return counted }
        let reset = ISO8601DateParser.parse(pool?.resetTime)
        // Both schemas can describe the same reset with timestamps up to two seconds apart.
        if let counted, let countedReset = counted.resetsAt, let reset,
           abs(countedReset.timeIntervalSince(reset)) <= 2, counted.usedPercent > ratio * 100
        {
            return counted
        }
        return QuotaWindow(title: title, usedPercent: ratio * 100, resetsAt: reset)
    }

    private static func countWindow(_ title: String, count: KimiUsageDetail?) -> QuotaWindow? {
        guard let count, let limit = Int64(count.limit), limit > 0 else { return nil }
        let used: Int64
        if let value = count.used.flatMap(Int64.init), value >= 0 {
            used = value
        } else if let remaining = count.remaining.flatMap(Int64.init), (0...limit).contains(remaining) {
            used = limit - remaining
        } else {
            return nil
        }
        return QuotaWindow(
            title: title,
            usedPercent: Decimal(used) * 100 / Decimal(limit),
            resetsAt: ISO8601DateParser.parse(count.resetTime))
    }
}
