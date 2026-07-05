import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Public models

public struct DeepSeekStatusComponentSnapshot: Sendable, Equatable {
    public let id: String
    public let name: String
    /// Flashcat status token (`operational`, `degraded`, `partial_outage`, …).
    public let status: String

    public init(id: String, name: String, status: String) {
        self.id = id
        self.name = name
        self.status = status
    }
}

public struct DeepSeekStatusSummary: Sendable, Equatable {
    public let indicator: String
    public let description: String?
    public let updatedAt: Date?
    public let components: [DeepSeekStatusComponentSnapshot]

    public init(
        indicator: String,
        description: String?,
        updatedAt: Date?,
        components: [DeepSeekStatusComponentSnapshot])
    {
        self.indicator = indicator
        self.description = description
        self.updatedAt = updatedAt
        self.components = components
    }
}

public enum DeepSeekStatusFetcher {
    public static let statusPageID = "6410630422455"
    public static let activeSummaryURL =
        "https://status.deepseek.com/api/status-page/\(statusPageID)/summary/active"

    public static func fetchSummary(
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared)
        async throws -> DeepSeekStatusSummary
    {
        guard let url = URL(string: self.activeSummaryURL) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, _) = try await transport.data(for: request)
        return try self.parseActiveSummary(data: data)
    }

    public static func parseActiveSummary(data: Data) throws -> DeepSeekStatusSummary {
        let response = try JSONDecoder().decode(ActiveSummaryResponse.self, from: data)
        guard let page = response.data?.page else {
            throw URLError(.cannotParseResponse)
        }

        let definitions = (page.components ?? [])
            .sorted { ($0.orderID ?? 0) < ($1.orderID ?? 0) }

        var statusByComponentID: [String: String] = [:]
        for definition in definitions {
            statusByComponentID[definition.componentID] = "operational"
        }

        let activeChanges = response.data?.activeChanges ?? []
        for change in activeChanges {
            for affected in change.affectedComponents ?? [] {
                guard let status = affected.status?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !status.isEmpty
                else { continue }
                statusByComponentID[affected.componentID] = Self.worstStatus(
                    statusByComponentID[affected.componentID] ?? "operational",
                    status)
            }

            if let latest = change.updates?.max(by: { ($0.atSeconds ?? 0) < ($1.atSeconds ?? 0) }) {
                for affected in latest.componentChanges ?? [] {
                    guard let status = affected.status?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !status.isEmpty
                    else { continue }
                    statusByComponentID[affected.componentID] = Self.worstStatus(
                        statusByComponentID[affected.componentID] ?? "operational",
                        status)
                }
            }
        }

        let components = definitions.map { definition in
            DeepSeekStatusComponentSnapshot(
                id: definition.componentID,
                name: Self.displayName(definition.name),
                status: statusByComponentID[definition.componentID] ?? "operational")
        }

        let worstComponentStatus = components
            .map(\.status)
            .max(by: { Self.statusRank($0) < Self.statusRank($1) }) ?? "operational"

        let description = activeChanges
            .compactMap { change -> String? in
                guard let title = change.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty
                else { return nil }
                return title
            }
            .first

        let updatedAt = activeChanges
            .flatMap { $0.updates ?? [] }
            .compactMap(\.atSeconds)
            .max()
            .map { Date(timeIntervalSince1970: TimeInterval($0)) }

        return DeepSeekStatusSummary(
            indicator: Self.overallIndicator(forWorstStatus: worstComponentStatus),
            description: description,
            updatedAt: updatedAt,
            components: components)
    }

    static func displayName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.lastIndex(of: "("),
              let close = trimmed.lastIndex(of: ")"),
              open < close
        else { return trimmed }

        let inner = trimmed[trimmed.index(after: open)..<close]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? trimmed : String(inner)
    }

    public static func normalizedStatuspageStatus(_ raw: String) -> String {
        switch raw {
        case "degraded": "degraded_performance"
        case "full_outage": "major_outage"
        default: raw
        }
    }

    static func worstStatus(_ lhs: String, _ rhs: String) -> String {
        self.statusRank(lhs) >= self.statusRank(rhs) ? lhs : rhs
    }

    static func statusRank(_ status: String) -> Int {
        switch status {
        case "operational": 0
        case "degraded", "degraded_performance": 1
        case "partial_outage": 2
        case "major_outage", "full_outage": 3
        case "under_maintenance": 1
        default: 1
        }
    }

    static func overallIndicator(forWorstStatus status: String) -> String {
        switch status {
        case "operational": "none"
        case "degraded", "degraded_performance": "minor"
        case "partial_outage": "major"
        case "major_outage", "full_outage": "critical"
        case "under_maintenance": "maintenance"
        default: "minor"
        }
    }
}

// MARK: - Response decoding

private struct ActiveSummaryResponse: Decodable {
    let data: DataPayload?

    struct DataPayload: Decodable {
        let page: Page?
        let activeChanges: [ActiveChange]?

        private enum CodingKeys: String, CodingKey {
            case page
            case activeChanges = "active_changes"
        }
    }

    struct Page: Decodable {
        let components: [ComponentDefinition]?
    }

    struct ComponentDefinition: Decodable {
        let componentID: String
        let name: String
        let orderID: Int?

        private enum CodingKeys: String, CodingKey {
            case componentID = "component_id"
            case name
            case orderID = "order_id"
        }
    }

    struct ActiveChange: Decodable {
        let title: String?
        let affectedComponents: [AffectedComponent]?
        let updates: [ChangeUpdate]?

        private enum CodingKeys: String, CodingKey {
            case title
            case affectedComponents = "affected_components"
            case updates
        }
    }

    struct AffectedComponent: Decodable {
        let componentID: String
        let status: String?

        private enum CodingKeys: String, CodingKey {
            case componentID = "component_id"
            case status
        }
    }

    struct ChangeUpdate: Decodable {
        let atSeconds: Int?
        let componentChanges: [AffectedComponent]?

        private enum CodingKeys: String, CodingKey {
            case atSeconds = "at_seconds"
            case componentChanges = "component_changes"
        }
    }
}
