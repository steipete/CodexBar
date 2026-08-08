import Foundation

public struct ProviderDetailSection: Codable, Equatable, Sendable {
    public static let maximumSectionsPerSnapshot = 8
    public static let maximumRowsPerSection = 24
    public static let maximumPointsPerChart = 120
    public static let maximumStringLength = 120

    public struct Row: Codable, Equatable, Sendable {
        /// Numeric progress behind a row, when the provider knows both sides of a ratio.
        ///
        /// Rows are display strings by design; the bar needs real numbers, so a row that should
        /// render a progress indicator carries the ratio here instead of a second representation.
        public struct Progress: Codable, Equatable, Sendable {
            public let used: Double
            public let total: Double

            /// Percent of the total consumed.
            ///
            /// Intentionally not clamped: overage-permitted plans can exceed 100%, and `RateWindow`
            /// documents the same convention of leaving provider values un-normalized. Display
            /// clamping belongs to the renderer.
            public var usedPercent: Double {
                (self.used / self.total) * 100
            }

            public init(used: Double, total: Double) throws {
                guard used.isFinite, total.isFinite else {
                    throw ValidationError("row.progress values must be finite")
                }
                guard total > 0 else {
                    throw ValidationError("row.progress.total must be positive")
                }
                self.used = used
                self.total = total
            }

            private enum CodingKeys: String, CodingKey {
                case used
                case total
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try self.init(
                    used: container.decode(Double.self, forKey: .used),
                    total: container.decode(Double.self, forKey: .total))
            }
        }

        /// Optional stable identifier, for rows a feature must find again (tests, clearing a
        /// specific row from a stored snapshot). Not required for purely presentational rows.
        public let id: String?
        public let label: String
        public let value: String
        public let secondaryValue: String?
        public let progress: Progress?

        public init(
            id: String? = nil,
            label: String,
            value: String,
            secondaryValue: String? = nil,
            progress: Progress? = nil) throws
        {
            self.id = try ProviderDetailSection.optionalString(id, path: "row.id")
            self.label = try ProviderDetailSection.requiredString(label, path: "row.label")
            self.value = try ProviderDetailSection.requiredString(value, path: "row.value")
            self.secondaryValue = try ProviderDetailSection.optionalString(secondaryValue, path: "row.secondaryValue")
            self.progress = progress
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case label
            case value
            case secondaryValue
            case progress
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                id: container.decodeIfPresent(String.self, forKey: .id),
                label: container.decode(String.self, forKey: .label),
                value: container.decode(String.self, forKey: .value),
                secondaryValue: container.decodeIfPresent(String.self, forKey: .secondaryValue),
                progress: container.decodeIfPresent(Progress.self, forKey: .progress))
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

extension ProviderDetailSection {
    static func makeRow(
        id: String? = nil,
        label: String,
        value: String,
        secondaryValue: String? = nil,
        progress: Row.Progress? = nil) -> Row
    {
        do {
            return try Row(
                id: self.boundedOptional(id),
                label: self.boundedRequired(label),
                value: self.boundedRequired(value),
                secondaryValue: self.boundedOptional(secondaryValue),
                progress: progress)
        } catch {
            preconditionFailure("Bounded provider detail row failed validation: \(error)")
        }
    }

    static func makeChart(
        kind: Chart.Kind = .bars,
        title: String? = nil,
        unit: String? = nil,
        points: [(label: String, value: Double)]) -> Chart
    {
        do {
            return try Chart(
                kind: kind,
                title: self.boundedOptional(title),
                unit: self.boundedOptional(unit),
                points: points.prefix(self.maximumPointsPerChart).compactMap { point in
                    guard point.value.isFinite else { return nil }
                    return try? Chart.Point(label: self.boundedRequired(point.label), value: point.value)
                })
        } catch {
            preconditionFailure("Bounded provider detail chart failed validation: \(error)")
        }
    }

    static func makeSection(title: String? = nil, rows: [Row], chart: Chart? = nil) -> Self {
        do {
            return try Self(
                title: self.boundedOptional(title),
                rows: Array(rows.prefix(self.maximumRowsPerSection)),
                chart: chart)
        } catch {
            preconditionFailure("Bounded provider detail section failed validation: \(error)")
        }
    }

    private static func boundedRequired(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "—" : trimmed).prefix(self.maximumStringLength))
    }

    private static func boundedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(self.maximumStringLength))
    }
}

extension ProviderDetailSection.Row {
    static func makeRow(
        id: String? = nil,
        label: String,
        value: String,
        secondaryValue: String? = nil,
        progress: Progress? = nil) -> Self
    {
        ProviderDetailSection.makeRow(
            id: id,
            label: label,
            value: value,
            secondaryValue: secondaryValue,
            progress: progress)
    }
}

extension ProviderDetailSection.Row.Progress {
    /// Non-throwing variant for call sites that already hold validated numbers.
    static func makeProgress(used: Double, total: Double) -> Self {
        do {
            return try Self(used: used, total: total)
        } catch {
            preconditionFailure("Bounded provider detail row progress failed validation: \(error)")
        }
    }
}

extension ProviderDetailSection.Chart {
    static func makeChart(
        kind: Kind = .bars,
        title: String? = nil,
        unit: String? = nil,
        points: [(label: String, value: Double)]) -> Self
    {
        ProviderDetailSection.makeChart(kind: kind, title: title, unit: unit, points: points)
    }
}
