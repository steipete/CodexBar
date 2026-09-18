import Foundation

package enum ProviderStatusIndicator: String, Encodable, Sendable {
    case none
    case minor
    case major
    case critical
    case maintenance
    case unknown

    package var hasIssue: Bool {
        self != .none
    }
}

package struct ProviderStatus: Sendable {
    package let indicator: ProviderStatusIndicator
    package let description: String?
    package let updatedAt: Date?

    package init(indicator: ProviderStatusIndicator, description: String?, updatedAt: Date?) {
        self.indicator = indicator
        self.description = description
        self.updatedAt = updatedAt
    }
}

/// A status service or a group of services. Raw statuses remain separate from localized display labels.
package struct ProviderStatusComponent: Identifiable, Equatable, Sendable {
    package let id: String
    package let name: String
    package let indicator: ProviderStatusIndicator
    package let status: String
    package var children: [ProviderStatusComponent]

    package init(
        id: String,
        name: String,
        indicator: ProviderStatusIndicator,
        status: String,
        children: [ProviderStatusComponent] = [])
    {
        self.id = id
        self.name = name
        self.indicator = indicator
        self.status = status
        self.children = children
    }

    package var isGroup: Bool {
        !self.children.isEmpty
    }

    package static func indicator(forStatuspageStatus status: String) -> ProviderStatusIndicator {
        switch status {
        case "operational": .none
        case "degraded_performance": .minor
        case "partial_outage": .major
        case "major_outage", "full_outage": .critical
        case "under_maintenance": .maintenance
        default: .unknown
        }
    }
}
