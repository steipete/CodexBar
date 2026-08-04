import Foundation

public struct ProviderDetailSection: Codable, Equatable, Sendable {
    public static let maximumSectionsPerSnapshot = 8
    public static let maximumRowsPerSection = 24
    public static let maximumPointsPerChart = 120
    public static let maximumStringLength = 120

    public struct Row: Codable, Equatable, Sendable {
        public let label: String
        public let value: String
        public let secondaryValue: String?

        public init(label: String, value: String, secondaryValue: String? = nil) throws {
            self.label = try ProviderDetailSection.requiredString(label, path: "row.label")
            self.value = try ProviderDetailSection.requiredString(value, path: "row.value")
            self.secondaryValue = try ProviderDetailSection.optionalString(secondaryValue, path: "row.secondaryValue")
        }

        private enum CodingKeys: String, CodingKey {
            case label
            case value
            case secondaryValue
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                label: container.decode(String.self, forKey: .label),
                value: container.decode(String.self, forKey: .value),
                secondaryValue: container.decodeIfPresent(String.self, forKey: .secondaryValue))
        }
    }

    public struct Chart: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Equatable, Sendable {
            case bars
            case line
        }

        public struct Point: Codable, Equatable, Sendable {
            public let label: String
            public let value: Double

            public init(label: String, value: Double) throws {
                self.label = try ProviderDetailSection.requiredString(label, path: "chart.point.label")
                guard value.isFinite else {
                    throw ValidationError("chart.point.value must be finite")
                }
                self.value = value
            }

            private enum CodingKeys: String, CodingKey {
                case label
                case value
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try self.init(
                    label: container.decode(String.self, forKey: .label),
                    value: container.decode(Double.self, forKey: .value))
            }
        }

        public let kind: Kind
        public let title: String?
        public let unit: String?
        public let points: [Point]

        public init(kind: Kind, title: String? = nil, unit: String? = nil, points: [Point]) throws {
            guard points.count <= ProviderDetailSection.maximumPointsPerChart else {
                throw ValidationError(
                    "chart.points exceeds \(ProviderDetailSection.maximumPointsPerChart) entries")
            }
            self.kind = kind
            self.title = try ProviderDetailSection.optionalString(title, path: "chart.title")
            self.unit = try ProviderDetailSection.optionalString(unit, path: "chart.unit")
            self.points = points
        }

        private enum CodingKeys: String, CodingKey {
            case kind
            case title
            case unit
            case points
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                kind: container.decode(Kind.self, forKey: .kind),
                title: container.decodeIfPresent(String.self, forKey: .title),
                unit: container.decodeIfPresent(String.self, forKey: .unit),
                points: container.decode([Point].self, forKey: .points))
        }
    }

    public struct ValidationError: LocalizedError, Equatable, Sendable {
        public let message: String

        public init(_ message: String) {
            self.message = message
        }

        public var errorDescription: String? {
            self.message
        }
    }

    public let title: String?
    public let rows: [Row]
    public let chart: Chart?

    public init(title: String? = nil, rows: [Row] = [], chart: Chart? = nil) throws {
        guard rows.count <= Self.maximumRowsPerSection else {
            throw ValidationError("section.rows exceeds \(Self.maximumRowsPerSection) entries")
        }
        self.title = try Self.optionalString(title, path: "section.title")
        self.rows = rows
        self.chart = chart
    }

    public static func validateSections(_ sections: [Self]) throws {
        guard sections.count <= self.maximumSectionsPerSnapshot else {
            throw ValidationError("snapshot.details exceeds \(self.maximumSectionsPerSnapshot) sections")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case rows
        case chart
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            title: container.decodeIfPresent(String.self, forKey: .title),
            rows: container.decode([Row].self, forKey: .rows),
            chart: container.decodeIfPresent(Chart.self, forKey: .chart))
    }

    private static func requiredString(_ rawValue: String, path: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw ValidationError("\(path) must not be empty")
        }
        guard value.count <= Self.maximumStringLength else {
            throw ValidationError("\(path) exceeds \(Self.maximumStringLength) characters")
        }
        return value
    }

    private static func optionalString(_ rawValue: String?, path: String) throws -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= Self.maximumStringLength else {
            throw ValidationError("\(path) exceeds \(Self.maximumStringLength) characters")
        }
        return value.isEmpty ? nil : value
    }
}
