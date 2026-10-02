import Foundation

public enum LangdockUsageError: LocalizedError, Sendable, Equatable {
    case unsupportedPlatform
    case profileRequired
    case profileUnavailable
    case profileUnreadable
    case browserAccessPaused
    case sessionUnavailable
    case sessionChanged
    case unauthorized
    case forbidden
    case rejected(String)
    case httpStatus(Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform: "Langdock web usage requires macOS and Microsoft Edge."
        case .profileRequired: "Select the Edge profile used for Langdock in provider settings."
        case .profileUnavailable: "The selected Edge profile has no discoverable cookie store."
        case .profileUnreadable:
            "CodexBar cannot read the selected Edge profile. " +
                "Check Files & Folders access for this CodexBar build."
        case .browserAccessPaused:
            "Edge cookie access is blocked. " +
                "Check CodexBar's Keychain access setting and refresh manually."
        case .sessionUnavailable: "No usable Langdock session was found in the selected Edge profile."
        case .sessionChanged: "The Langdock session in the selected Edge profile changed. Refresh again."
        case .unauthorized: "The selected Edge profile is no longer signed in to Langdock."
        case .forbidden: "Langdock denied access to personal usage for this session."
        case let .rejected(code): "Langdock rejected the usage request (\(code))."
        case let .httpStatus(status): "Langdock usage request failed with HTTP \(status)."
        case .invalidResponse: "Langdock returned an unexpected personal usage response."
        }
    }
}

public enum LangdockUsageParser {
    private struct Envelope: Decodable {
        struct Result: Decodable {
            struct DataBody: Decodable {
                let json: Payload
            }

            let data: DataBody
        }

        struct RPCError: Decodable {
            struct Body: Decodable {
                struct Details: Decodable {
                    let code: String?
                }

                let data: Details?
            }

            let json: Body?
        }

        let result: Result?
        let error: RPCError?
    }

    private struct Payload: Decodable {
        let hasIncludedUsageLimits: Bool?
        let planUsage: PlanUsage?
    }

    private struct PlanUsage: Decodable {
        let sessionUsageLimitsEnabled: Bool
        let sessionUsagePercent: Double?
        let sessionResetsAt: String?
        let weeklyUsagePercent: Double
        let weeklyResetsAt: String?
    }

    public static func parse(_ data: Data, statusCode: Int, now: Date = Date()) throws -> UsageSnapshot {
        if statusCode == 401 { throw LangdockUsageError.unauthorized }
        if statusCode == 403 { throw LangdockUsageError.forbidden }
        guard (200..<300).contains(statusCode) else { throw LangdockUsageError.httpStatus(statusCode) }
        guard let envelopes = try? JSONDecoder().decode([Envelope].self, from: data),
              envelopes.count == 1
        else { throw LangdockUsageError.invalidResponse }
        let envelope = envelopes[0]
        if let code = envelope.error?.json?.data?.code {
            switch code {
            case "UNAUTHORIZED": throw LangdockUsageError.unauthorized
            case "FORBIDDEN": throw LangdockUsageError.forbidden
            default: throw LangdockUsageError.rejected(code)
            }
        }
        guard let payload = envelope.result?.data.json else { throw LangdockUsageError.invalidResponse }
        guard payload.hasIncludedUsageLimits != false, let plan = payload.planUsage else {
            return UsageSnapshot(
                primary: nil,
                secondary: nil,
                details: [.makeSection(title: "Usage", rows: [
                    .makeRow(label: "Included limits", value: "No included usage limits available"),
                ])],
                updatedAt: now,
                dataConfidence: .percentOnly)
        }
        guard plan.weeklyUsagePercent.isFinite,
              !plan.sessionUsageLimitsEnabled || (plan.sessionUsagePercent?.isFinite == true)
        else { throw LangdockUsageError.invalidResponse }
        let sessionReset = try self.parseDate(plan.sessionResetsAt)
        let weeklyReset = try self.parseDate(plan.weeklyResetsAt)
        let primary: RateWindow? = if plan.sessionUsageLimitsEnabled, let used = plan.sessionUsagePercent {
            RateWindow(usedPercent: used, windowMinutes: 300, resetsAt: sessionReset, resetDescription: nil)
        } else {
            nil
        }
        let secondary = RateWindow(
            usedPercent: plan.weeklyUsagePercent,
            windowMinutes: 10080,
            resetsAt: weeklyReset,
            resetDescription: nil)
        return UsageSnapshot(primary: primary, secondary: secondary, updatedAt: now, dataConfidence: .percentOnly)
    }

    private static func parseDate(_ raw: String?) throws -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        guard let date = standard.date(from: raw) else { throw LangdockUsageError.invalidResponse }
        return date
    }
}
