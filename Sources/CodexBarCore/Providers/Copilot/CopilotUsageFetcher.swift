import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CopilotUsageFetcher: Sendable {
    private let token: String

    public init(token: String) {
        self.token = token
    }

    public func fetch() async throws -> UsageSnapshot {
        guard let url = URL(string: "https://api.github.com/copilot_internal/user") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        // Use the GitHub OAuth token directly, not the Copilot token.
        request.setValue("token \(self.token)", forHTTPHeaderField: "Authorization")
        self.addCommonHeaders(to: &request)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw URLError(.userAuthenticationRequired)
        }

        guard httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let usage = try JSONDecoder().decode(CopilotUsageResponse.self, from: data)
        let premium = self.makeRateWindow(from: usage.quotaSnapshots.premiumInteractions)
        let chat = self.makeRateWindow(from: usage.quotaSnapshots.chat)

        let primary: RateWindow?
        let secondary: RateWindow?
        if let premium {
            primary = premium
            secondary = chat
        } else if let chatWindow = chat {
            // Keep chat in the secondary slot so provider labels remain accurate
            // ("Premium" for primary, "Chat" for secondary) on chat-only plans.
            primary = nil
            secondary = chatWindow
        } else {
            throw URLError(.cannotDecodeRawData)
        }

        let identity = ProviderIdentitySnapshot(
            providerID: .copilot,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: usage.copilotPlan.capitalized)
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            providerCost: nil,
            updatedAt: Date(),
            identity: identity)
    }

    private func addCommonHeaders(to request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
        request.setValue("copilot-chat/0.26.7", forHTTPHeaderField: "Editor-Plugin-Version")
        request.setValue("GitHubCopilotChat/0.26.7", forHTTPHeaderField: "User-Agent")
        request.setValue("2025-04-01", forHTTPHeaderField: "X-Github-Api-Version")
    }

    private func makeRateWindow(from snapshot: CopilotUsageResponse.QuotaSnapshot?) -> RateWindow? {
        guard let snapshot else { return nil }
        guard !snapshot.isPlaceholder else { return nil }
        guard snapshot.hasPercentRemaining else { return nil }
        // percent_remaining is 0-100 based on the JSON example in the web app source
        let usedPercent = max(0, 100 - snapshot.percentRemaining)

        return RateWindow(
            usedPercent: usedPercent,
            windowMinutes: nil, // Not provided
            resetsAt: nil, // Not provided per-quota in the simplified snapshot
            resetDescription: nil)
    }
}
