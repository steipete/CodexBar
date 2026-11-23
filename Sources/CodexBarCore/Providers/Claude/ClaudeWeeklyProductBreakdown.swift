import Foundation

/// How this week's usage splits across Claude products (`seven_day_breakdown`). Each `percent` is a share of the
/// week's usage, not a separate quota, so the shares compose 100 and never replace the weekly bar.
public struct ClaudeWeeklyProductBreakdown: Decodable, Equatable, Sendable {
    public struct Product: Decodable, Equatable, Sendable {
        public let key: String
        public let name: String
        public let sharePercent: Double

        private enum CodingKeys: String, CodingKey {
            case key
            case name = "display_name"
            case sharePercent = "percent"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.key = try container.decode(String.self, forKey: .key).trimmingCharacters(in: .whitespacesAndNewlines)
            let name = try container.decodeIfPresent(String.self, forKey: .name)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.name = name.flatMap { $0.isEmpty ? nil : $0 } ?? self.key
            self.sharePercent = try container.decode(Double.self, forKey: .sharePercent)
            guard !self.key.isEmpty, self.sharePercent.isFinite, (0...100).contains(self.sharePercent) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .sharePercent, in: container, debugDescription: "Invalid product share")
            }
        }
    }

    public static let detailTitle = "Usage breakdown"
    /// Whole-number shares of four products can round up to 2 points away from 100.
    private static let compositionTolerancePercent = 2.0

    public let products: [Product]

    private enum CodingKeys: String, CodingKey {
        case rows
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.products = try container.decode([Product].self, forKey: .rows)
        // Any malformed row drops the whole breakdown rather than showing shares that no longer add up.
        let sum = self.products.reduce(0) { $0 + $1.sharePercent }
        guard abs(sum - 100) <= Self.compositionTolerancePercent else {
            throw DecodingError.dataCorruptedError(
                forKey: .rows, in: container, debugDescription: "Product shares do not compose the week")
        }
    }

    /// Web JSON and OAuth decoding share the same validation.
    static func parse(_ value: Any?) -> Self? {
        guard let object = value as? [String: Any],
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object)
        else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func detailSections() -> [ProviderDetailSection] {
        // `sorted` is stable, so equal shares keep the response order.
        let rows = self.products
            .filter { $0.sharePercent > 0 }
            .sorted { $0.sharePercent > $1.sharePercent }
            .map { product in
                ProviderDetailSection.makeRow(
                    id: "claude.product.\(product.key)",
                    label: product.name,
                    value: UsageFormatter.percentString(product.sharePercent))
            }
        guard !rows.isEmpty else { return [] }
        return [.makeSection(title: Self.detailTitle, rows: rows)]
    }
}
