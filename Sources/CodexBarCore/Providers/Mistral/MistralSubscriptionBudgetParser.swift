import Foundation

struct MistralSubscriptionBudgets: Hashable, Sendable {
    let api: MistralSubscriptionBudget?
    let vibe: MistralSubscriptionBudget?
}

struct MistralSubscriptionBudget: Hashable, Sendable {
    let usagePercentage: Double
    let limit: Double
    let currencyCode: String
    let resetsAt: Date?

    var usedAmount: Double {
        self.limit * (self.usagePercentage / 100)
    }

    var remainingAmount: Double {
        max(self.limit - self.usedAmount, 0)
    }
}

enum MistralSubscriptionBudgetParser {
    private struct RawBudget: Decodable {
        let usagePercentage: Double
        let initialBudget: Double
        let currency: String
        let resetAt: String?

        enum CodingKeys: String, CodingKey {
            case usagePercentage = "usage_percentage"
            case initialBudget = "initial_budget"
            case currency
            case resetAt = "reset_at"
        }
    }

    enum ParseError: Error, Equatable {
        case budgetNotFound
        case ambiguousBudgets
        case invalidRecord
    }

    private static let flightPushMarker = Data("self.__next_f.push(".utf8)
    private static let lengthDelimitedTags = Set("TAOoUSsLlGgMmV".utf8)

    static func parse(html: String) throws -> MistralSubscriptionBudgets {
        let stream = Data(self.flightChunks(in: html).joined().utf8)
        var matches: Set<MistralSubscriptionBudgets> = []
        try self.collectModels(in: stream) { root in
            self.collectBudgets(in: root, into: &matches)
        }
        guard let budgets = matches.first else { throw ParseError.budgetNotFound }
        guard matches.count == 1 else { throw ParseError.ambiguousBudgets }
        return budgets
    }

    private static func flightChunks(in html: String) -> [String] {
        let data = Data(html.utf8)
        var cursor = data.startIndex
        var chunks: [String] = []
        while cursor < data.endIndex,
              let markerRange = data.range(of: self.flightPushMarker, in: cursor..<data.endIndex)
        {
            var start = markerRange.upperBound
            while start < data.endIndex, self.isWhitespace(data[start]) {
                start = data.index(after: start)
            }
            guard start < data.endIndex, data[start] == UInt8(ascii: "[") else {
                cursor = markerRange.upperBound
                continue
            }
            guard let end = self.jsonContainerEnd(in: data, from: start) else {
                cursor = data.index(after: start)
                continue
            }
            let encoded = data.subdata(in: start..<end)
            if let array = try? JSONSerialization.jsonObject(with: encoded) as? [Any],
               array.count >= 2,
               let channel = array[0] as? Int,
               channel == 1,
               let chunk = array[1] as? String
            {
                chunks.append(chunk)
            }
            cursor = end
        }
        return chunks
    }

    private static func collectModels(in data: Data, body: (Any) -> Void) throws {
        var cursor = data.startIndex
        while cursor < data.endIndex {
            let lineEnd = data[cursor...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
            guard let colon = data[cursor..<lineEnd].firstIndex(of: UInt8(ascii: ":")),
                  colon > cursor,
                  data[cursor..<colon].allSatisfy(self.isHexDigit)
            else {
                cursor = lineEnd < data.endIndex ? data.index(after: lineEnd) : lineEnd
                continue
            }
            let start = data.index(after: colon)
            if start < lineEnd, self.lengthDelimitedTags.contains(data[start]) {
                guard let comma = data[start..<lineEnd].firstIndex(of: UInt8(ascii: ",")) else {
                    throw ParseError.invalidRecord
                }
                let lengthBytes = data[data.index(after: start)..<comma]
                // Text/binary Flight rows are byte-counted and can contain fake JSON rows and newlines.
                let payloadStart = data.index(after: comma)
                guard !lengthBytes.isEmpty, lengthBytes.allSatisfy(self.isHexDigit),
                      let lengthString = String(bytes: lengthBytes, encoding: .utf8),
                      let length = Int(lengthString, radix: 16),
                      length <= data.distance(from: payloadStart, to: data.endIndex)
                else { throw ParseError.invalidRecord }
                cursor = data.index(payloadStart, offsetBy: length)
                continue
            }
            if start < lineEnd, data[start] == UInt8(ascii: "[") || data[start] == UInt8(ascii: "{") {
                guard let root = try? JSONSerialization.jsonObject(with: data.subdata(in: start..<lineEnd)) else {
                    throw ParseError.invalidRecord
                }
                body(root)
            }
            cursor = lineEnd < data.endIndex ? data.index(after: lineEnd) : lineEnd
        }
    }

    private static func collectBudgets(in value: Any, into results: inout Set<MistralSubscriptionBudgets>) {
        if let dictionary = value as? [String: Any] {
            if let raw = dictionary["budget"] as? [String: Any] {
                let budgets = MistralSubscriptionBudgets(
                    api: self.budget(from: raw["api_budget"]),
                    vibe: self.budget(from: raw["vibe_budget"]))
                if budgets.api != nil || budgets.vibe != nil {
                    results.insert(budgets)
                }
            }
            for child in dictionary.values {
                self.collectBudgets(in: child, into: &results)
            }
        } else if let array = value as? [Any] {
            for child in array {
                self.collectBudgets(in: child, into: &results)
            }
        }
    }

    private static func jsonContainerEnd(in data: Data, from start: Data.Index) -> Data.Index? {
        var expectedClosers: [UInt8] = []
        var inString = false
        var escaped = false
        var index = start
        while index < data.endIndex {
            let byte = data[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
            } else {
                switch byte {
                case UInt8(ascii: "\""):
                    inString = true
                case UInt8(ascii: "["):
                    expectedClosers.append(UInt8(ascii: "]"))
                case UInt8(ascii: "{"):
                    expectedClosers.append(UInt8(ascii: "}"))
                case UInt8(ascii: "]"), UInt8(ascii: "}"):
                    guard expectedClosers.last == byte else { return nil }
                    expectedClosers.removeLast()
                    if expectedClosers.isEmpty { return data.index(after: index) }
                default:
                    break
                }
            }
            index = data.index(after: index)
        }
        return nil
    }

    private static func budget(from value: Any?) -> MistralSubscriptionBudget? {
        guard let dictionary = value as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: dictionary),
              let raw = try? JSONDecoder().decode(RawBudget.self, from: data)
        else { return nil }
        let currency = raw.currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard raw.usagePercentage.isFinite, raw.usagePercentage >= 0,
              raw.initialBudget.isFinite, raw.initialBudget > 0, !currency.isEmpty
        else { return nil }
        let budget = MistralSubscriptionBudget(
            usagePercentage: raw.usagePercentage,
            limit: raw.initialBudget,
            currencyCode: currency,
            resetsAt: ISO8601DateParser.parse(raw.resetAt))
        return budget.usedAmount.isFinite ? budget : nil
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 9 || byte == 10 || byte == 13 || byte == 32
    }
}
