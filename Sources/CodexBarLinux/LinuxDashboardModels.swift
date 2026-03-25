import CodexBarCore
import Foundation

struct LinuxProviderPayload: Decodable, Sendable {
    let provider: String
    let account: String?
    let version: String?
    let source: String
    let status: LinuxProviderStatusPayload?
    let usage: UsageSnapshot?
    let credits: CreditsSnapshot?
    let antigravityPlanInfo: AntigravityPlanInfoSummary?
    let openaiDashboard: OpenAIDashboardSnapshot?
    let error: LinuxProviderErrorPayload?

    var resolvedProvider: UsageProvider? {
        UsageProvider(rawValue: self.provider)
    }

    var metadata: ProviderMetadata? {
        guard let provider = self.resolvedProvider else { return nil }
        return ProviderDescriptorRegistry.descriptor(for: provider).metadata
    }

    var displayName: String {
        self.metadata?.displayName ?? self.provider.capitalized
    }

    var updatedAt: Date? {
        if let usage = self.usage { return usage.updatedAt }
        if let credits = self.credits { return credits.updatedAt }
        if let openaiDashboard = self.openaiDashboard { return openaiDashboard.updatedAt }
        if let status = self.status { return status.updatedAt }
        return nil
    }

    var statusURL: String? {
        if let status = self.status { return status.url }
        if let metadata = self.metadata {
            return metadata.statusLinkURL ?? metadata.statusPageURL
        }
        return nil
    }

    var dashboardURL: String? {
        self.metadata?.dashboardURL ?? self.metadata?.subscriptionDashboardURL
    }

    var identityLines: [String] {
        guard let usage = self.usage else { return [] }
        let identity = usage.identity(for: self.resolvedProvider ?? .codex) ?? usage.identity

        var lines: [String] = []
        if let account = self.account, !account.isEmpty {
            lines.append("Cuenta: \(account)")
        } else if let email = identity?.accountEmail, !email.isEmpty {
            lines.append("Cuenta: \(email)")
        }
        if let organization = identity?.accountOrganization, !organization.isEmpty {
            lines.append("Org: \(organization)")
        }
        if let loginMethod = identity?.loginMethod, !loginMethod.isEmpty {
            lines.append("Plan: \(loginMethod)")
        }
        return lines
    }
}

struct LinuxProviderStatusPayload: Decodable, Sendable {
    let indicator: String
    let description: String?
    let updatedAt: Date?
    let url: String
}

struct LinuxProviderErrorPayload: Decodable, Sendable {
    let code: Int32
    let message: String
    let kind: String?
}

struct LinuxDashboardSnapshot: Sendable {
    let generatedAt: Date
    let providers: [LinuxProviderPayload]

    var healthyProviderCount: Int {
        self.providers.filter { $0.error == nil }.count
    }

    var failedProviderCount: Int {
        self.providers.filter { $0.error != nil }.count
    }

    var headline: String {
        if self.providers.isEmpty {
            return "No hay providers configurados todavia"
        }
        if self.failedProviderCount > 0 {
            return "\(self.healthyProviderCount) providers activos, \(self.failedProviderCount) con error"
        }
        return "\(self.providers.count) providers activos"
    }

    var topSummary: String {
        let leading = self.providers
            .compactMap { payload -> String? in
                guard let primary = payload.usage?.primary else { return nil }
                let label = payload.metadata?.cliName ?? payload.provider
                return "\(label) \(Int(primary.remainingPercent.rounded()))%"
            }
            .prefix(3)
        if leading.isEmpty { return "Esperando datos de uso" }
        return leading.joined(separator: " | ")
    }

    var waybarText: String {
        if self.failedProviderCount > 0 {
            return "CB !\(self.failedProviderCount)"
        }
        let leading = self.providers.compactMap { payload -> String? in
            guard let primary = payload.usage?.primary else { return nil }
            let label = payload.metadata?.cliName ?? payload.provider
            return "\(label):\(Int(primary.remainingPercent.rounded()))%"
        }
        if leading.isEmpty { return "CB idle" }
        return "CB " + leading.prefix(2).joined(separator: " ")
    }

    var waybarTooltip: String {
        let rows = self.providers.map { payload -> String in
            if let error = payload.error {
                return "\(payload.displayName): error \(error.message)"
            }
            if let primary = payload.usage?.primary {
                return "\(payload.displayName): \(Int(primary.remainingPercent.rounded()))% restante"
            }
            if let credits = payload.credits {
                return "\(payload.displayName): \(UsageFormatter.creditsString(from: credits.remaining))"
            }
            return "\(payload.displayName): sin datos"
        }
        return rows.joined(separator: "\n")
    }

    var waybarClass: String {
        self.failedProviderCount > 0 ? "error" : "ok"
    }
}

struct LinuxWaybarPayload: Encodable {
    let text: String
    let tooltip: String
    let `class`: String
}
