import Crypto
import Foundation

/// Identity evidence retained by a native reader; anonymous rows cannot be combined safely.
public enum UsageLedgerIdentity: String, Codable, Sendable {
    case request
    case legacyEvent
    case unidentified
}

/// Numeric usage only. Identity hashes never contain a host, filesystem path or conversation text.
public struct UsageLedgerRecord: Codable, Sendable, Equatable {
    public var id: String
    public var sessionID: String?
    public var identity: UsageLedgerIdentity
    public var timestampUnixMs: Int64
    public var model: String
    public var inputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var cacheWrite1hTokens: Int
    public var outputTokens: Int
    public var reasoningTokens: Int?
    /// Native reader total; Codex input already includes cache reads, whereas Claude input does not.
    public var totalTokens: Int
    public var costUSD: Double?
    public var costProvenance: CostProvenance
    public var pricingModel: String?
    public var pricingMode: String?

    public init(
        id: String,
        sessionID: String? = nil,
        identity: UsageLedgerIdentity,
        timestampUnixMs: Int64,
        model: String,
        inputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int = 0,
        outputTokens: Int,
        totalTokens: Int,
        costUSD: Double?,
        cacheWrite1hTokens: Int = 0,
        reasoningTokens: Int? = nil,
        costProvenance: CostProvenance = .unknown,
        pricingModel: String? = nil,
        pricingMode: String? = nil)
    {
        self.id = id
        self.sessionID = sessionID
        self.identity = identity
        self.timestampUnixMs = timestampUnixMs
        self.model = model
        self.inputTokens = inputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cacheWrite1hTokens = cacheWrite1hTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = totalTokens
        self.costUSD = costUSD
        self.costProvenance = costProvenance
        self.pricingModel = pricingModel
        self.pricingMode = pricingMode
    }

    /// UTF-8 length framing prevents delimiter collisions between identity components.
    public static func digest(_ components: [String]) -> String {
        let data = Data(components.map { "\($0.utf8.count):\($0)" }.joined().utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Explicit, bounded native-history export. This is neither an invoice nor account-wide telemetry.
public struct UsageLedger: Codable, Sendable {
    public var schemaVersion = 1
    public var provider: String
    public var updatedAt: Date
    public var historyDays: Int
    public var windowStartUnixMs: Int64
    public var windowEndUnixMs: Int64
    public var bucketTimeZone: String
    public var coverageIsEstablished: Bool
    public var records: [UsageLedgerRecord]
    public var incompleteRequestCount: Int
    public var warnings: [String]

    public init(
        provider: String,
        updatedAt: Date,
        historyDays: Int,
        bucketTimeZone: String,
        coverageIsEstablished: Bool,
        records: [UsageLedgerRecord],
        incompleteRequestCount: Int = 0,
        warnings: [String] = [])
    {
        self.provider = provider
        self.updatedAt = updatedAt
        self.historyDays = historyDays
        self.bucketTimeZone = bucketTimeZone
        let calendar = CostUsageBucketTimeZone.calendar(identifier: bucketTimeZone)
        let start = calendar.date(byAdding: .day, value: 1 - historyDays, to: calendar.startOfDay(for: updatedAt))
            ?? updatedAt
        self.windowStartUnixMs = Int64(start.timeIntervalSince1970 * 1000)
        self.windowEndUnixMs = Int64((updatedAt.timeIntervalSince1970 * 1000).rounded())
        self.coverageIsEstablished = coverageIsEstablished
        self.records = records
        self.incompleteRequestCount = incompleteRequestCount
        self.warnings = warnings
    }
}

public enum UsageLedgerLoader {
    /// Reads native local history only; never probes provider credentials or transfers transcripts.
    public static func load(
        provider: UsageProvider, historyDays: Int, now: Date = Date(), calendar: Calendar = .current)
        async throws -> UsageLedger
    {
        guard (1...365).contains(historyDays), now.timeIntervalSince1970.isFinite,
              (0...253_402_300_799).contains(now.timeIntervalSince1970),
              let start = calendar.date(
                  byAdding: .day, value: 1 - historyDays, to: calendar.startOfDay(for: now)),
              start.timeIntervalSince1970 >= 0
        else { throw UsageLedgerError.invalid("Invalid ledger history window.") }
        var ledger = switch provider {
        case .codex: try await self.loadCodex(historyDays: historyDays, now: now, calendar: calendar)
        case .claude: try await self.loadClaude(historyDays: historyDays, now: now, calendar: calendar)
        default: throw UsageLedgerError.invalid("Only native Codex and Claude history is supported.")
        }
        ledger.windowStartUnixMs = Int64(start.timeIntervalSince1970 * 1000)
        ledger.windowEndUnixMs = Int64((now.timeIntervalSince1970 * 1000).rounded())
        ledger.records.removeAll {
            $0.timestampUnixMs < ledger.windowStartUnixMs || $0.timestampUnixMs > ledger.windowEndUnixMs
        }
        return ledger
    }
}

public enum UsageLedgerError: LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(message): message
        }
    }
}
