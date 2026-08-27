import Foundation

/// How a cost figure was produced. This is display-time accounting, not a billing receipt.
public enum CostProvenance: String, Sendable, Equatable, Codable {
    /// Token counts × public API list prices.
    case listPriceEstimate
    /// Vendor-reported metered spend (for example Cursor plan deductions).
    case vendorMetered
    /// Window mixes list-price rows with vendor-metered rows.
    case mixed
    case unknown

    public var isBillingReceipt: Bool {
        false
    }

    /// Narrow a snapshot-level provenance to the costs actually present in a window.
    /// Daily vendor-reported rows stay vendor-metered even when `meteredCostUSD` is absent.
    public static func forWindow(
        snapshot: CostProvenance,
        hasWindowCosts: Bool,
        includesMetered: Bool) -> CostProvenance
    {
        switch snapshot {
        case .vendorMetered:
            includesMetered || hasWindowCosts ? .vendorMetered : .unknown
        case .mixed:
            switch (includesMetered, hasWindowCosts) {
            case (true, true):
                .mixed
            case (true, false):
                .vendorMetered
            case (false, true):
                .listPriceEstimate
            case (false, false):
                .unknown
            }
        case .listPriceEstimate:
            hasWindowCosts ? .listPriceEstimate : .unknown
        case .unknown:
            .unknown
        }
    }
}

/// Request/row coverage for a cost window. Counts stay independent so a missing
/// category is `0` rather than collapsing into another bucket.
public struct CostUsageCoverageCounts: Sendable, Equatable, Codable {
    public var priced: Int
    public var unpriced: Int
    public var unmetered: Int
    public var estimated: Int

    public init(priced: Int = 0, unpriced: Int = 0, unmetered: Int = 0, estimated: Int = 0) {
        self.priced = max(0, priced)
        self.unpriced = max(0, unpriced)
        self.unmetered = max(0, unmetered)
        self.estimated = max(0, estimated)
    }

    public var total: Int {
        self.priced + self.unpriced + self.unmetered + self.estimated
    }

    public var coverageRatio: Double? {
        let measured = self.priced + self.estimated
        let denominator = self.total
        guard denominator > 0 else { return nil }
        return Double(measured) / Double(denominator)
    }

    public mutating func merge(_ other: CostUsageCoverageCounts) {
        self.priced += other.priced
        self.unpriced += other.unpriced
        self.unmetered += other.unmetered
        self.estimated += other.estimated
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        var merged = lhs
        merged.merge(rhs)
        return merged
    }
}

/// Token-class mix. `nil` means the source did not establish that class — never treat as zero.
public struct CostUsageTokenMix: Sendable, Equatable, Codable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheCreationTokens: Int?
    public var reasoningTokens: Int?
    /// Transient aggregation state, not a new persisted token field.
    private var overflowedClasses: UInt8 = 0

    private enum CodingKeys: String, CodingKey {
        case inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens, reasoningTokens
    }

    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheCreationTokens: Int? = nil,
        reasoningTokens: Int? = nil)
    {
        self.inputTokens = Self.nonnegative(inputTokens)
        self.outputTokens = Self.nonnegative(outputTokens)
        self.cacheReadTokens = Self.nonnegative(cacheReadTokens)
        self.cacheCreationTokens = Self.nonnegative(cacheCreationTokens)
        self.reasoningTokens = Self.nonnegative(reasoningTokens)
    }

    public var hasAnyClass: Bool {
        self.inputTokens != nil
            || self.outputTokens != nil
            || self.cacheReadTokens != nil
            || self.cacheCreationTokens != nil
            || self.reasoningTokens != nil
    }

    public mutating func merge(_ other: CostUsageTokenMix) {
        self.overflowedClasses |= other.overflowedClasses
        self.inputTokens = self.add(self.inputTokens, other.inputTokens, bit: 1)
        self.outputTokens = self.add(self.outputTokens, other.outputTokens, bit: 2)
        self.cacheReadTokens = self.add(self.cacheReadTokens, other.cacheReadTokens, bit: 4)
        self.cacheCreationTokens = self.add(self.cacheCreationTokens, other.cacheCreationTokens, bit: 8)
        self.reasoningTokens = self.add(self.reasoningTokens, other.reasoningTokens, bit: 16)
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        var merged = lhs
        merged.merge(rhs)
        return merged
    }

    public static func from(entry: CostUsageDailyReport.Entry) -> Self {
        Self(
            inputTokens: entry.inputTokens,
            outputTokens: entry.outputTokens,
            cacheReadTokens: entry.cacheReadTokens,
            cacheCreationTokens: entry.cacheCreationTokens,
            reasoningTokens: entry.reasoningTokens)
    }

    private static func nonnegative(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return value
    }

    private mutating func add(_ lhs: Int?, _ rhs: Int?, bit: UInt8) -> Int? {
        guard self.overflowedClasses & bit == 0 else { return nil }
        switch (lhs, rhs) {
        case let (left?, right?):
            let (result, overflow) = left.addingReportingOverflow(right)
            if overflow { self.overflowedClasses |= bit }
            return overflow ? nil : result
        case let (left?, nil):
            return left
        case let (nil, right?):
            return right
        case (nil, nil):
            return nil
        }
    }
}

/// Pinned IANA timezone used to bucket cost-usage days. Re-bucketing the same history
/// under a different zone would move midnight-adjacent events and inflate totals.
public enum CostUsageBucketTimeZone: Sendable {
    public static func calendar(identifier: String?) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = self.timeZone(identifier: identifier)
        return calendar
    }

    public static func timeZone(identifier: String?) -> TimeZone {
        if let identifier {
            let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, let zone = TimeZone(identifier: trimmed) {
                return zone
            }
        }
        return .current
    }

    public static func pinIdentifier(from timeZone: TimeZone = .current) -> String {
        timeZone.identifier
    }

    public static func isValidIdentifier(_ identifier: String) -> Bool {
        TimeZone(identifier: identifier) != nil
    }
}
