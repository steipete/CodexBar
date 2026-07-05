import CoreFoundation
import Foundation

/// Strictly parsed result of `cswap --list --json` (schema v1).
///
/// Only the fields allow-listed in `docs/claude-multi-account-and-status-items.md`
/// are decoded: slot number, display email, active state, usage status, and the
/// 5-hour/7-day windows (percent + reset timestamp). Everything else in the
/// payload is ignored; unknown schema versions and partial top-level shapes are
/// rejected.
public struct ClaudeSwapAccountList: Equatable, Sendable {
    public let activeAccountNumber: Int?
    public let accounts: [ClaudeSwapAccountRow]

    public init(activeAccountNumber: Int?, accounts: [ClaudeSwapAccountRow]) {
        self.activeAccountNumber = activeAccountNumber
        self.accounts = accounts
    }
}

public struct ClaudeSwapAccountRow: Equatable, Sendable {
    public let number: Int
    /// Display-only sensitive value; never logged or persisted.
    public let email: String
    public let isActive: Bool
    public let usageStatus: ClaudeSwapUsageStatus
    public let fiveHour: ClaudeSwapUsageWindow?
    public let sevenDay: ClaudeSwapUsageWindow?

    public init(
        number: Int,
        email: String,
        isActive: Bool,
        usageStatus: ClaudeSwapUsageStatus,
        fiveHour: ClaudeSwapUsageWindow?,
        sevenDay: ClaudeSwapUsageWindow?)
    {
        self.number = number
        self.email = email
        self.isActive = isActive
        self.usageStatus = usageStatus
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }
}

public struct ClaudeSwapUsageWindow: Equatable, Sendable {
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(usedPercent: Double, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

/// The sentinel statuses `cswap` emits per account. Unknown values from newer
/// claude-swap releases are preserved rather than failing the whole payload.
public enum ClaudeSwapUsageStatus: Equatable, Sendable {
    case ok
    case tokenExpired
    case apiKey
    case keychainUnavailable
    case noCredentials
    case unavailable
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "ok": self = .ok
        case "token_expired": self = .tokenExpired
        case "api_key": self = .apiKey
        case "keychain_unavailable": self = .keychainUnavailable
        case "no_credentials": self = .noCredentials
        case "unavailable": self = .unavailable
        default: self = .unknown(rawValue)
        }
    }
}

public enum ClaudeSwapListParserError: LocalizedError, Equatable, Sendable {
    case notJSONObject
    case missingSchemaVersion
    case unsupportedSchemaVersion(Int)
    case reportedError(type: String, message: String)
    case malformedShape(String)

    public var errorDescription: String? {
        switch self {
        case .notJSONObject:
            "claude-swap returned output that is not a JSON object."
        case .missingSchemaVersion:
            "claude-swap output has no schemaVersion field."
        case let .unsupportedSchemaVersion(version):
            "claude-swap output uses unsupported schema version \(version); CodexBar supports version 1."
        case let .reportedError(type, message):
            "claude-swap reported \(type): \(message)"
        case let .malformedShape(details):
            "claude-swap output is malformed: \(details)"
        }
    }
}

public enum ClaudeSwapListParser {
    public static let supportedSchemaVersion = 1

    public static func parse(_ data: Data) throws -> ClaudeSwapAccountList {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ClaudeSwapListParserError.notJSONObject
        }
        guard let object = raw as? [String: Any] else {
            throw ClaudeSwapListParserError.notJSONObject
        }
        guard let schemaVersion = object["schemaVersion"] as? Int else {
            throw ClaudeSwapListParserError.missingSchemaVersion
        }
        guard schemaVersion == self.supportedSchemaVersion else {
            throw ClaudeSwapListParserError.unsupportedSchemaVersion(schemaVersion)
        }
        if let errorObject = object["error"] as? [String: Any] {
            throw ClaudeSwapListParserError.reportedError(
                type: errorObject["type"] as? String ?? "Error",
                message: errorObject["message"] as? String ?? "unknown error")
        }
        guard let rawAccounts = object["accounts"] as? [Any] else {
            throw ClaudeSwapListParserError.malformedShape("missing accounts array")
        }
        guard let rawActiveAccountNumber = object["activeAccountNumber"] else {
            throw ClaudeSwapListParserError.malformedShape("missing activeAccountNumber")
        }
        let activeAccountNumber: Int? = switch rawActiveAccountNumber {
        case is NSNull: nil
        case let number as Int where number > 0: number
        default:
            throw ClaudeSwapListParserError.malformedShape("activeAccountNumber is not a numeric slot or null")
        }
        var seenSlots: Set<Int> = []
        let accounts = try rawAccounts.map { rawRow -> ClaudeSwapAccountRow in
            guard let row = rawRow as? [String: Any] else {
                throw ClaudeSwapListParserError.malformedShape("account row is not an object")
            }
            let account = try self.parseRow(row)
            guard seenSlots.insert(account.number).inserted else {
                throw ClaudeSwapListParserError.malformedShape("duplicate account slot \(account.number)")
            }
            return account
        }
        let activeSlots = accounts.filter(\.isActive).map(\.number)
        guard activeSlots == (activeAccountNumber.map { [$0] } ?? []) else {
            throw ClaudeSwapListParserError.malformedShape("active account fields disagree")
        }
        return ClaudeSwapAccountList(activeAccountNumber: activeAccountNumber, accounts: accounts)
    }

    private static func parseRow(_ row: [String: Any]) throws -> ClaudeSwapAccountRow {
        guard let number = row["number"] as? Int else {
            throw ClaudeSwapListParserError.malformedShape("account row has no numeric slot")
        }
        guard number > 0 else {
            throw ClaudeSwapListParserError.malformedShape("account slot must be positive")
        }
        guard let isActive = row["active"] as? Bool else {
            throw ClaudeSwapListParserError.malformedShape("slot \(number) has no active flag")
        }
        guard let rawStatus = row["usageStatus"] as? String else {
            throw ClaudeSwapListParserError.malformedShape("slot \(number) has no usageStatus")
        }
        let email = (row["email"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let usage = row["usage"] as? [String: Any]
        return try ClaudeSwapAccountRow(
            number: number,
            email: email,
            isActive: isActive,
            usageStatus: ClaudeSwapUsageStatus(rawValue: rawStatus),
            fiveHour: self.parseWindow(usage?["fiveHour"], slot: number, name: "fiveHour"),
            sevenDay: self.parseWindow(usage?["sevenDay"], slot: number, name: "sevenDay"))
    }

    private static func parseWindow(_ raw: Any?, slot: Int, name: String) throws -> ClaudeSwapUsageWindow? {
        guard let raw else { return nil }
        guard let window = raw as? [String: Any] else {
            throw ClaudeSwapListParserError.malformedShape("slot \(slot) \(name) window is not an object")
        }
        guard let pct = Self.finiteDouble(window["pct"]) else {
            throw ClaudeSwapListParserError.malformedShape("slot \(slot) \(name) percent is not a finite number")
        }
        var resetsAt: Date?
        if let rawResetsAt = window["resetsAt"] {
            guard let text = rawResetsAt as? String, let date = Self.parseTimestamp(text) else {
                throw ClaudeSwapListParserError.malformedShape("slot \(slot) \(name) resetsAt is not a timestamp")
            }
            resetsAt = date
        }
        return ClaudeSwapUsageWindow(usedPercent: min(max(pct, 0), 100), resetsAt: resetsAt)
    }

    private static func finiteDouble(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber else { return nil }
        // JSON booleans bridge to NSNumber too; only accept genuine numbers.
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    private static func parseTimestamp(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
