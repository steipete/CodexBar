import CoreFoundation
import Foundation

public struct HuggingFaceWebCreditsSnapshot: Equatable, Sendable {
    public let balanceUSD: Double

    public init(balanceUSD: Double) {
        self.balanceUSD = balanceUSD
    }
}

/// Parses the prepaid wallet from Hugging Face's authenticated billing page.
///
/// This intentionally accepts only the server-rendered data contract established by FP-157. Visible
/// billing text and usage/entitlement fields are not inputs to this parser.
public enum HuggingFaceWebCreditsParser {
    public enum ParseError: Error, Equatable, Sendable {
        case unavailable
        case malformedHTML
        case malformedJSON
        case invalidCurrentBalance
        case ambiguousCurrentBalance
        case invalidLegacyBalance
        case ambiguousLegacyBalance
    }

    private static let maxSafeInteger = 9_007_199_254_740_991.0
    private static let divPattern = Self.regularExpression(#"<div\b[^>]*>"#)
    private static let dataPropsPattern = Self.regularExpression(
        #"\bdata-props\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#)

    private static func regularExpression(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            preconditionFailure("Invalid built-in Hugging Face billing markup pattern")
        }
    }

    public static func parse(_ html: String) throws -> Double {
        try self.parseSnapshot(html).balanceUSD
    }

    public static func parseSnapshot(_ html: String) throws -> HuggingFaceWebCreditsSnapshot {
        let payloads = try self.dataPropsPayloads(in: html)
        guard !payloads.isEmpty else { throw ParseError.unavailable }

        var currentEntities: [[String: Any]] = []
        var legacyValues: [Any] = []
        for payload in payloads {
            guard let data = payload.data(using: .utf8) else {
                throw ParseError.malformedJSON
            }
            guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                throw ParseError.malformedJSON
            }
            guard let dictionary = object as? [String: Any] else { continue }

            let entity = dictionary["entity"] as? [String: Any]
            if let entity, entity.keys.contains("currentBalanceUsd") {
                guard entity["type"] as? String == "user" else {
                    throw ParseError.invalidCurrentBalance
                }
                currentEntities.append(entity)
            }
            if let legacy = dictionary["invoiceCreditsCents"] {
                legacyValues.append(legacy)
            }
        }

        if !currentEntities.isEmpty {
            guard currentEntities.count == 1 else {
                throw ParseError.ambiguousCurrentBalance
            }
            let entity = currentEntities[0]
            guard let value = self.nonNegativeFiniteNumber(entity["currentBalanceUsd"]) else {
                throw ParseError.invalidCurrentBalance
            }
            return HuggingFaceWebCreditsSnapshot(balanceUSD: value)
        }

        guard !legacyValues.isEmpty else { throw ParseError.unavailable }
        guard legacyValues.count == 1 else { throw ParseError.ambiguousLegacyBalance }
        guard let cents = self.legacyCents(legacyValues[0]) else {
            throw ParseError.invalidLegacyBalance
        }
        return HuggingFaceWebCreditsSnapshot(balanceUSD: cents / 100)
    }

    private static func dataPropsPayloads(in html: String) throws -> [String] {
        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let divMatches = self.divPattern.matches(in: html, options: [], range: fullRange)
        var payloads: [String] = []
        payloads.reserveCapacity(divMatches.count)
        for divMatch in divMatches {
            let tag = (html as NSString).substring(with: divMatch.range)
            guard let propsMatch = self.dataPropsPattern.firstMatch(
                in: tag,
                options: [],
                range: NSRange(tag.startIndex..<tag.endIndex, in: tag))
            else { continue }

            let valueRange = (1...3).lazy
                .map { propsMatch.range(at: $0) }
                .first { $0.location != NSNotFound }
            guard let valueRange else { throw ParseError.malformedHTML }
            let raw = (tag as NSString).substring(with: valueRange)
            try payloads.append(self.decodeHTML(raw))
        }
        return payloads
    }

    private static func decodeHTML(_ value: String) throws -> String {
        var decoded = ""
        var index = value.startIndex
        while index < value.endIndex {
            guard value[index] == "&" else {
                decoded.append(value[index])
                index = value.index(after: index)
                continue
            }

            guard let semicolon = value[index...].firstIndex(of: ";") else {
                decoded.append("&")
                index = value.index(after: index)
                continue
            }
            let bodyStart = value.index(after: index)
            let body = String(value[bodyStart..<semicolon])
            guard let scalar = self.entityScalar(body) else {
                throw ParseError.malformedHTML
            }
            decoded.append(Character(scalar))
            index = value.index(after: semicolon)
        }
        return decoded
    }

    private static func entityScalar(_ body: String) -> Unicode.Scalar? {
        switch body {
        // Provider-specific by design: "amp" decodes the HTML entity used in data-props JSON.
        case "amp": return "&"
        case "apos": return "'"
        case "gt": return ">"
        case "lt": return "<"
        case "nbsp": return "\u{00A0}"
        case "quot": return "\""
        default:
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                guard let value = UInt32(body.dropFirst(2), radix: 16) else { return nil }
                return Unicode.Scalar(value)
            }
            if body.hasPrefix("#"), let value = UInt32(body.dropFirst(), radix: 10) {
                return Unicode.Scalar(value)
            }
            return nil
        }
    }

    private static func nonNegativeFiniteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        guard result.isFinite, result >= 0 else { return nil }
        return result
    }

    private static func legacyCents(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let cents = number.doubleValue
        guard cents.isFinite,
              cents >= 0,
              cents <= self.maxSafeInteger,
              cents.rounded() == cents
        else { return nil }
        return cents
    }
}
