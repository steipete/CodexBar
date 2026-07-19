import CoreFoundation
import Foundation

/// Allow-listed result of `cswap --switch-to <slot> --json` (schema v1).
public struct ClaudeSwapAccountSwitchResult: Equatable, Sendable {
    public let switched: Bool
    public let fromAccountNumber: Int?
    public let toAccountNumber: Int
    public let reason: String

    public init(switched: Bool, fromAccountNumber: Int?, toAccountNumber: Int, reason: String) {
        self.switched = switched
        self.fromAccountNumber = fromAccountNumber
        self.toAccountNumber = toAccountNumber
        self.reason = reason
    }
}

public enum ClaudeSwapSwitchParserError: LocalizedError, Equatable, Sendable {
    case notJSONObject
    case missingSchemaVersion
    case unsupportedSchemaVersion(Int)
    case reportedError(type: String, message: String)
    case malformedShape(String)
    case mismatchedTarget(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .notJSONObject:
            "claude-swap returned switch output that is not a JSON object."
        case .missingSchemaVersion:
            "claude-swap switch output has no schemaVersion field."
        case let .unsupportedSchemaVersion(version):
            "claude-swap switch output uses unsupported schema version \(version); CodexBar supports version 1."
        case let .reportedError(type, message):
            "claude-swap reported \(type): \(message)"
        case let .malformedShape(details):
            "claude-swap switch output is malformed: \(details)"
        case let .mismatchedTarget(expected, actual):
            "claude-swap reported account slot \(actual) after CodexBar requested slot \(expected)."
        }
    }
}

public enum ClaudeSwapSwitchParser {
    public static func parse(_ data: Data) throws -> ClaudeSwapAccountSwitchResult {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ClaudeSwapSwitchParserError.notJSONObject
        }
        guard let object = raw as? [String: Any] else {
            throw ClaudeSwapSwitchParserError.notJSONObject
        }
        guard let schemaVersion = self.integer(object["schemaVersion"]) else {
            throw ClaudeSwapSwitchParserError.missingSchemaVersion
        }
        guard schemaVersion == ClaudeSwapListParser.supportedSchemaVersion else {
            throw ClaudeSwapSwitchParserError.unsupportedSchemaVersion(schemaVersion)
        }
        if let errorObject = object["error"] as? [String: Any] {
            throw ClaudeSwapSwitchParserError.reportedError(
                type: errorObject["type"] as? String ?? "Error",
                message: errorObject["message"] as? String ?? "unknown error")
        }
        guard let switched = object["switched"] as? Bool else {
            throw ClaudeSwapSwitchParserError.malformedShape("missing switched flag")
        }
        guard let reason = (object["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty
        else {
            throw ClaudeSwapSwitchParserError.malformedShape("missing reason")
        }
        let fromAccountNumber = try self.accountNumber(
            in: object["from"],
            field: "from",
            allowsNull: true)
        guard let toAccountNumber = try self.accountNumber(
            in: object["to"],
            field: "to",
            allowsNull: false)
        else {
            throw ClaudeSwapSwitchParserError.malformedShape("to account has no numeric slot")
        }
        return ClaudeSwapAccountSwitchResult(
            switched: switched,
            fromAccountNumber: fromAccountNumber,
            toAccountNumber: toAccountNumber,
            reason: reason)
    }

    private static func accountNumber(in raw: Any?, field: String, allowsNull: Bool) throws -> Int? {
        if raw is NSNull, allowsNull { return nil }
        guard let account = raw as? [String: Any] else {
            throw ClaudeSwapSwitchParserError.malformedShape("missing \(field) account")
        }
        guard let rawNumber = account["number"] else {
            throw ClaudeSwapSwitchParserError.malformedShape("\(field) account has no number")
        }
        if rawNumber is NSNull, allowsNull { return nil }
        guard let number = self.integer(rawNumber), number > 0
        else {
            throw ClaudeSwapSwitchParserError.malformedShape("\(field) account number is not a positive slot")
        }
        return number
    }

    private static func integer(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        return raw as? Int
    }
}
