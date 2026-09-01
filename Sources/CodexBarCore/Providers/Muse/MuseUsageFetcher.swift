import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum MuseUsageFetcher {
    private static let requestTimeoutSeconds: TimeInterval = 15

    public static func fetchUsage(
        apiKey: String,
        baseURL: URL = MuseSettingsReader.baseURL(),
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> MuseUsageSnapshot
    {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MuseUsageError.missingCredentials
        }

        // Try to fetch account/usage from Meta API. If the endpoint is not yet
        // published or returns non-2xx, fall back to a minimal snapshot that
        // proves the key is present. This keeps the provider useful on day one
        // while allowing a real quota fetch once Meta publishes the endpoint.
        if let snapshot = try await self.tryFetchQuota(apiKey: trimmed, baseURL: baseURL, transport: transport) {
            return snapshot
        }

        // Fallback: key is present but no quota endpoint responded.
        // Return identity-only snapshot so the menu shows "API key configured".
        return MuseUsageSnapshot(
            primary: nil,
            secondary: nil,
            accountEmail: nil,
            plan: "API Key",
            updatedAt: Date())
    }

    private static func tryFetchQuota(
        apiKey: String,
        baseURL: URL,
        transport: any ProviderHTTPTransport) async throws -> MuseUsageSnapshot?
    {
        // Candidate endpoints — Meta has not published a stable usage endpoint yet.
        // We probe a small list and treat 404/501 as "not available".
        let candidates = [
            baseURL.appendingPathComponent("usage"),
            baseURL.appendingPathComponent("billing/usage"),
            baseURL.appendingPathComponent("me"),
            URL(string: "https://api.meta.ai/v1/usage")!,
        ]

        for url in candidates {
            do {
                let snapshot = try await self.fetchFromURL(url, apiKey: apiKey, transport: transport)
                if snapshot != nil {
                    return snapshot
                }
            } catch let error as MuseUsageError {
                // Invalid key should surface immediately.
                if case .invalidAPIKey = error {
                    throw error
                }
                continue
            } catch {
                continue
            }
        }
        return nil
    }

    private static func fetchFromURL(
        _ url: URL,
        apiKey: String,
        transport: any ProviderHTTPTransport) async throws -> MuseUsageSnapshot?
    {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = self.requestTimeoutSeconds
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexBar/1.0 (Muse)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MuseUsageError.networkError("Invalid response")
        }

        switch http.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw MuseUsageError.invalidAPIKey
        case 404, 501:
            return nil
        default:
            throw MuseUsageError.networkError("HTTP \(http.statusCode)")
        }

        // Try to parse a flexible JSON shape. We support multiple possible
        // server schemas so we can adapt once Meta publishes the real one.
        return self.parseSnapshot(data: data)
    }

    static func parseSnapshot(data: Data) -> MuseUsageSnapshot? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Common patterns: {usage:{...}}, {data:{...}}, or flat.
        let root = (json["data"] as? [String: Any]) ?? json
        let usage = (root["usage"] as? [String: Any]) ?? root

        var primary: RateWindow?
        var secondary: RateWindow?

        if let session = usage["session"] as? [String: Any] ?? usage["five_hour"] as? [String: Any] {
            primary = self.rateWindow(from: session, label: "Session")
        } else if let used = usage["used_percent"] as? Double {
            primary = RateWindow(usedPercent: used, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        }

        if let weekly = usage["weekly"] as? [String: Any] ?? usage["seven_day"] as? [String: Any] {
            secondary = self.rateWindow(from: weekly, label: "Weekly")
        }

        let email = (root["email"] as? String) ?? (root["account"] as? [String: Any])?["email"] as? String
        let plan = (root["plan"] as? String) ?? (root["tier"] as? String) ?? (root["subscription"] as? String)

        // If we parsed nothing useful, return nil to try next endpoint.
        if primary == nil, secondary == nil, email == nil, plan == nil {
            // Check for flat balance style: {balance, limit}
            if let balance = root["balance"] as? Double, let limit = root["limit"] as? Double, limit > 0 {
                let used = max(0, min(100, ((limit - balance) / limit) * 100))
                primary = RateWindow(usedPercent: used, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
                return MuseUsageSnapshot(primary: primary, accountEmail: email, plan: plan, updatedAt: Date())
            }
            return nil
        }

        return MuseUsageSnapshot(
            primary: primary,
            secondary: secondary,
            accountEmail: email,
            plan: plan,
            updatedAt: Date())
    }

    private static func rateWindow(from dict: [String: Any], label _: String) -> RateWindow? {
        let used: Double? = (dict["used_percent"] as? Double)
            ?? (dict["usedPercent"] as? Double)
            ?? (dict["percent_used"] as? Double)
            ?? {
                if let used = dict["used"] as? Double, let limit = dict["limit"] as? Double, limit > 0 {
                    return (used / limit) * 100
                }
                if let remaining = dict["remaining_percent"] as? Double {
                    return 100 - remaining
                }
                return nil
            }()

        guard let percent = used else { return nil }

        var resetsAt: Date?
        if let resetStr = dict["resets_at"] as? String ?? dict["resetsAt"] as? String {
            resetsAt = ISO8601DateFormatter().date(from: resetStr) ?? Self.parseDate(resetStr)
        } else if let resetInterval = dict["reset_in_seconds"] as? Double {
            resetsAt = Date().addingTimeInterval(resetInterval)
        }

        let resetDescription = dict["reset_description"] as? String ?? dict["resetDescription"] as? String
        let windowMinutes = dict["window_minutes"] as? Int ?? dict["windowMinutes"] as? Int

        return RateWindow(
            usedPercent: max(0, min(100, percent)),
            windowMinutes: windowMinutes,
            resetsAt: resetsAt,
            resetDescription: resetDescription)
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatters: [DateFormatter] = {
            let f1 = DateFormatter()
            f1.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
            f1.locale = Locale(identifier: "en_US_POSIX")
            let f2 = DateFormatter()
            f2.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
            f2.locale = Locale(identifier: "en_US_POSIX")
            return [f1, f2]
        }()
        for f in formatters {
            if let d = f.date(from: string) { return d }
        }
        return nil
    }
}
