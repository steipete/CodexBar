#if os(macOS)
import CryptoKit
import Foundation

/// The canonical Tokscale cache is authoritative once present; never combine it with migration CSVs.
enum CursorLocalJSONReader {
    enum Result {
        case absent
        case unavailable
        case report(Report)
    }

    struct Report {
        let daily: CostUsageDailyReport
        let meteredCostUSD: Double?
        let isComplete: Bool
    }

    static func load(
        home: URL? = nil,
        since: Date,
        until: Date,
        calendar: Calendar = .current,
        modelsDevCatalog: ModelsDevCatalog? = nil) -> Result
    {
        let url = CursorLocalCSVReader.cacheDirectory(home: home).appendingPathComponent("usage.json")
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { return .unavailable }
        } catch {
            let error = error as NSError
            return error.domain == NSCocoaErrorDomain
                && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
                ? .absent : .unavailable
        }
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(Document.self, from: data)
        else { return .unavailable }
        let rows = document.rows.compactMap(\.value)
        let isComplete = rows.count == document.rows.count
        let events = Self.deduplicated(rows).compactMap { row -> CursorUsageEvent? in
            let event = row.event
            guard let timestamp = event.validTimestampMS else { return nil }
            let date = Date(timeIntervalSince1970: Double(timestamp) / 1000)
            return date >= since && date <= until ? event : nil
        }
        return .report(Report(
            daily: CursorUsageEventsFetcher.makeDailyReport(
                from: events, calendar: calendar, modelsDevCatalog: modelsDevCatalog),
            meteredCostUSD: isComplete ? CursorUsageEventsFetcher.meteredCostUSD(from: events) : nil,
            isComplete: isComplete))
    }

    private static func deduplicated(_ rows: [Row]) -> [Row] {
        var identified: [Row.Identity: String] = [:]
        for row in rows {
            guard let id = row.id else { continue }
            identified[row.identity] = min(identified[row.identity] ?? id, id)
        }
        var winners: [String: Int] = [:]
        var keep = Array(repeating: true, count: rows.count)
        for (index, row) in rows.enumerated() {
            guard let id = row.id ?? identified[row.identity] else { continue }
            if let previous = winners[id] {
                let old = rows[previous]
                let tokens = row.event.tokenUsage?.totalTokens ?? 0
                let oldTokens = old.event.tokenUsage?.totalTokens ?? 0
                if tokens > oldTokens || (tokens == oldTokens && row.rankCost > old.rankCost) {
                    keep[previous] = false
                    winners[id] = index
                } else {
                    keep[index] = false
                }
            } else {
                winners[id] = index
            }
        }
        return rows.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
    }

    private enum InvalidCache: Error {
        case metadata
        case row
    }

    private struct Document: Decodable {
        let rows: [LossyRow]

        enum CodingKeys: String, CodingKey {
            case rows = "usageEventsDisplay"
            case owner = "_owner"
            case legacy = "_tokscale"
            case footer = "zzTokscaleOwner"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let hasEnvelope = container.contains(.owner) || container.contains(.footer)
            if container.contains(.legacy) || hasEnvelope {
                let legacy = try container.decode(LegacyOwner.self, forKey: .legacy)
                guard legacy.version == 1, !legacy.accountId.isEmpty else { throw InvalidCache.metadata }
                if hasEnvelope {
                    let owner = try container.decode(Owner.self, forKey: .owner)
                    let footer = try container.decode(Footer.self, forKey: .footer)
                    let hash = SHA256.hash(data: Data(legacy.accountId.utf8))
                        .map { String(format: "%02x", $0) }.joined()
                    guard owner.version == 1, footer.version == 1,
                          UUID(uuidString: owner.generation) != nil,
                          owner.generation == footer.generation, owner.ownerHash == hash
                    else { throw InvalidCache.metadata }
                }
            }
            self.rows = try container.decode([LossyRow].self, forKey: .rows)
        }
    }

    private struct Owner: Decodable {
        let version: Int
        let ownerHash: String
        let generation: String
    }

    private struct Footer: Decodable {
        let version: Int
        let generation: String
    }

    private struct LegacyOwner: Decodable {
        let version: Int
        let accountId: String
    }

    private struct LossyRow: Decodable {
        let value: Row?

        init(from decoder: Decoder) {
            self.value = try? Row(from: decoder)
        }
    }

    private struct Row: Decodable {
        struct Identity: Hashable {
            let conversation: String?
            let model: String
            let timestamp: Int64
        }

        let id: String?
        let identity: Identity
        let event: CursorUsageEvent

        var rankCost: Double {
            self.event.tokenUsage?.totalCents ?? self.event.chargedCents ?? 0
        }

        enum CodingKeys: String, CodingKey {
            case usageEventId, conversationId, timestamp, model, chargedCents, tokenUsage
        }

        init(from decoder: Decoder) throws {
            let conversation: String?
            let timestamp: Timestamp?
            let model: String?
            let charged: Amount?
            let usage: Tokens?
            if let container = try? decoder.container(keyedBy: CodingKeys.self) {
                self.id = Self.nonempty(try? container.decode(String.self, forKey: .usageEventId))
                conversation = Self.nonempty(try? container.decode(String.self, forKey: .conversationId))
                timestamp = try container.decodeIfPresent(Timestamp.self, forKey: .timestamp)
                model = Self.nonempty(try? container.decode(String.self, forKey: .model))
                charged = try container.decodeIfPresent(Amount.self, forKey: .chargedCents)
                usage = try container.decodeIfPresent(Tokens.self, forKey: .tokenUsage)
            } else {
                var container = try decoder.unkeyedContainer()
                self.id = nil
                conversation = try Self.nonempty(container.decodeIfPresent(String.self))
                timestamp = container.isAtEnd ? nil : try container.decodeIfPresent(Timestamp.self)
                model = try Self.nonempty(container.isAtEnd ? nil : container.decodeIfPresent(String.self))
                charged = container.isAtEnd ? nil : try container.decodeIfPresent(Amount.self)
                usage = container.isAtEnd ? nil : try container.decodeIfPresent(Tokens.self)
                guard container.isAtEnd else { throw InvalidCache.row }
            }
            guard let timestamp, let model else { throw InvalidCache.row }
            self.identity = Identity(conversation: conversation, model: model, timestamp: timestamp.milliseconds)
            self.event = CursorUsageEvent(
                timestampMS: timestamp.milliseconds,
                model: model,
                tokenUsage: usage?.value,
                chargedCents: charged?.value)
        }

        private static func nonempty(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
    }

    private struct Timestamp: Decodable {
        let milliseconds: Int64

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let milliseconds: Int64?
            if let value = try? container.decode(String.self) {
                let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if let numeric = Int64(value) ?? Double(value).flatMap(Int64.init(exactly:)) {
                    milliseconds = numeric
                } else {
                    let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
                        ?? (try? Date.ISO8601FormatStyle().parse(value))
                    milliseconds = date.flatMap {
                        Int64(exactly: ($0.timeIntervalSince1970 * 1000).rounded(.towardZero))
                    }
                }
            } else {
                milliseconds = (try? container.decode(Double.self)).flatMap(Int64.init(exactly:))
            }
            guard let milliseconds, milliseconds > 0, milliseconds <= 253_402_300_799_999 else {
                throw InvalidCache.row
            }
            self.milliseconds = milliseconds
        }
    }

    private struct Count: Decodable {
        let value: Int

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value: Int? = if let integer = try? container.decode(Int.self) {
                integer
            } else if let text = try? container.decode(String.self) {
                Int(text) ?? Double(text).flatMap(Int.init(exactly:))
            } else {
                (try? container.decode(Double.self)).flatMap(Int.init(exactly:))
            }
            guard let value, value >= 0 else { throw InvalidCache.row }
            self.value = value
        }
    }

    private struct Amount: Decodable {
        let cost: CursorEventTokenUsage.Cost

        var value: Double? {
            if case let .valid(value) = self.cost { return value }
            return nil
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value: Double?
            if container.decodeNil() {
                self.cost = .omitted
                return
            }
            if let text = try? container.decode(String.self) {
                value = Double(text)
            } else {
                value = try? container.decode(Double.self)
            }
            if let value, value.isFinite, value >= 0 {
                self.cost = .valid(value)
            } else {
                self.cost = .invalid
            }
        }
    }

    private struct Tokens: Decodable {
        let value: CursorEventTokenUsage

        enum CodingKeys: String, CodingKey {
            case inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, totalCents
        }

        init(from decoder: Decoder) throws {
            let input: Int
            let output: Int
            let read: Int
            let write: Int
            let cost: CursorEventTokenUsage.Cost
            if let container = try? decoder.container(keyedBy: CodingKeys.self) {
                input = try container.decodeIfPresent(Count.self, forKey: .inputTokens)?.value ?? 0
                output = try container.decodeIfPresent(Count.self, forKey: .outputTokens)?.value ?? 0
                read = try container.decodeIfPresent(Count.self, forKey: .cacheReadTokens)?.value ?? 0
                write = try container.decodeIfPresent(Count.self, forKey: .cacheWriteTokens)?.value ?? 0
                cost = try container.decodeIfPresent(Amount.self, forKey: .totalCents)?.cost ?? .omitted
            } else {
                var container = try decoder.unkeyedContainer()
                input = container.isAtEnd ? 0 : try container.decodeIfPresent(Count.self)?.value ?? 0
                output = container.isAtEnd ? 0 : try container.decodeIfPresent(Count.self)?.value ?? 0
                read = container.isAtEnd ? 0 : try container.decodeIfPresent(Count.self)?.value ?? 0
                write = container.isAtEnd ? 0 : try container.decodeIfPresent(Count.self)?.value ?? 0
                cost = container.isAtEnd ? .omitted : try container.decodeIfPresent(Amount.self)?.cost ?? .omitted
                guard container.isAtEnd else { throw InvalidCache.row }
            }
            guard CheckedSum.integers([input, output, read, write]) != nil else { throw InvalidCache.row }
            self.value = CursorEventTokenUsage(
                inputTokens: input, outputTokens: output, cacheWriteTokens: write, cacheReadTokens: read, cost: cost)
        }
    }
}
#endif
