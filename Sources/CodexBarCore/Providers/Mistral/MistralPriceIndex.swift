import Foundation

/// Unit prices from Mistral Admin, keyed the way Mistral bills: a billing metric can carry several prices for the
/// same billing group, one per event type (for example `mistral-medium-3-5` / `input` is priced for `api_tokens`
/// and for `api_audio_seconds`), and per API zone and service tier. Indexing on metric and group alone let a later
/// row overwrite the token price, which inflated Vibe Code spend by two orders of magnitude.
struct MistralPriceIndex: Sendable {
    struct Row: Sendable, Equatable {
        let eventType: String?
        let apiZone: String?
        let serviceTier: String?
        let price: Double
    }

    struct Lookup: Sendable {
        let billingMetric: String
        let billingGroup: String
        var eventType: String?
        var apiZone: String?
        var serviceTier: String?
    }

    static let tokenEventType = "api_tokens"
    static let tokenBillingGroups: Set<String> = ["input", "cached", "output"]

    private var rows: [String: [Row]] = [:]

    init() {}

    init(legacyPrices: [MistralPrice]) {
        for price in legacyPrices {
            guard let metric = price.billingMetric, let group = price.billingGroup,
                  let raw = price.price, let value = Double(raw), value.isFinite
            else { continue }
            self.add(
                billingMetric: metric,
                billingGroup: group,
                row: Row(
                    eventType: price.eventType,
                    apiZone: price.apiZone,
                    serviceTier: price.serviceTier,
                    price: value))
        }
    }

    mutating func add(billingMetric: String, billingGroup: String, row: Row) {
        self.rows[Self.key(billingMetric, billingGroup), default: []].append(row)
    }

    var isEmpty: Bool {
        self.rows.isEmpty
    }

    /// Event type a usage row is billed under. Explicit event types win; otherwise the price table decides, with
    /// `api_tokens` preferred for token lanes when a metric is priced for several event types.
    func resolvedEventType(for lookup: Lookup) -> String? {
        if let explicit = lookup.eventType?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        let candidates = Set(self.rows[Self.key(lookup.billingMetric, lookup.billingGroup)]?
            .compactMap(\.eventType) ?? [])
        if candidates.count == 1 { return candidates.first }
        if Self.tokenBillingGroups.contains(lookup.billingGroup), candidates.contains(Self.tokenEventType) {
            return Self.tokenEventType
        }
        return nil
    }

    func price(for lookup: Lookup) -> Double? {
        guard let rows = self.rows[Self.key(lookup.billingMetric, lookup.billingGroup)], !rows.isEmpty else {
            return nil
        }
        let eventType = self.resolvedEventType(for: lookup)
        let byEvent = rows.filter { eventType == nil || $0.eventType == nil || $0.eventType == eventType }
        guard !byEvent.isEmpty else { return nil }
        let zone = lookup.apiZone ?? "global"
        let tier = lookup.serviceTier ?? "standard"
        let ranked = byEvent.sorted { lhs, rhs in
            Self.rank(lhs, zone: zone, tier: tier) < Self.rank(rhs, zone: zone, tier: tier)
        }
        return ranked.first?.price
    }

    private static func rank(_ row: Row, zone: String, tier: String) -> Int {
        var score = 0
        if row.apiZone != nil, row.apiZone != zone { score += 2 }
        if row.serviceTier != nil, row.serviceTier != tier { score += 1 }
        return score
    }

    private static func key(_ metric: String, _ group: String) -> String {
        "\(metric)::\(group)"
    }
}
