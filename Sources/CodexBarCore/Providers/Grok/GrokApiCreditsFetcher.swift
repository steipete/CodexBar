import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches credits/usage directly from the xAI/Grok backend using the OAuth token
/// from ~/.grok/auth.json. This is more reliable than spawning the CLI.
///
/// The primary endpoint is the real gRPC-web call:
/// POST https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig
/// (discovered by inspecting the web UI at grok.com/?_s=usage)
///
/// SCAFFOLDING NOTE (for PR):
/// - Auth sharing with the official Grok CLI / VS Code extension is complete and working.
/// - We now call the actual production billing endpoint used by the Grok web UI.
/// - The protobuf response parser is currently best-effort (we will improve it
///   once we capture a real response from a Super Heavy account).
/// - The CLI-based probe (GrokCreditsProbe) is kept as fallback but is known to be
///   non-functional for headless /usage show.
public enum GrokApiCreditsFetcher {
    private static let log = CodexBarLog.logger(LogCategories.providers)

    // Accumulates debug output shown in Debug → Probe logs → Grok
    @MainActor
    private static var debugLogString: String = ""

    static func appendDebugLog(_ message: String) {
        Task { @MainActor in
            debugLogString += message + "\n\n"
            if debugLogString.count > 100_000 {
                debugLogString = String(debugLogString.suffix(70_000))
            }
        }
    }

    @MainActor
    public static var latestDebugLog: String {
        debugLogString.isEmpty
            ? "No Grok debug output yet.\n\nTry refreshing the Grok provider in the main Providers list."
            : debugLogString
    }

    /// Billing lives on grok.com per the CLI binary (billing.rs: "auth with grok.com").
    /// The /usage show command in the TUI fetches BillingPeriodUsage from here.
    private static let candidateBaseURLs: [String] = [
        "https://grok.com",
        "https://grok.com/api",
        "https://grok.com/_data/v1",
        "https://grok.com/rest",
        // Fallbacks (chat proxy does not expose billing)
        "https://cli-chat-proxy.grok.com/v1",
        "https://api.x.ai/v1",
    ]

    private static let usagePaths: [String] = [
        "/api/billing/usage",
        "/api/usage",
        "/_data/v1/billing/usage",
        "/_data/v1/usage",
        "/rest/billing/usage",
        "/billing/usage",
        "/api/billing/config",
        "/usage",
        "/credits",
    ]

    public static func fetch() async throws -> GrokCreditsSnapshot {
        guard let session = GrokCliSessionStore.loadIfPresent() else {
            throw GrokCliSessionError.notFound
        }

        let accessToken = session.accessToken

        // === Priority: Real gRPC-web endpoint discovered in browser ===
        // POST https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig
        // This is the exact call the web UI makes when you visit grok.com/?_s=usage
        if let snapshot = try? await fetchGrokBuildBillingCreditsConfig(accessToken: accessToken) {
            if snapshot.creditsUsedPercent != nil || snapshot.resetsAt != nil {
                log.info("Successfully fetched Grok credits via gRPC GetGrokCreditsConfig")
                return snapshot
            }
        }

        // === Fallback: previous REST guessing (kept temporarily) ===
        for baseURL in candidateBaseURLs {
            for path in usagePaths {
                let urlString = baseURL + path
                guard let url = URL(string: urlString) else { continue }

                do {
                    let snapshot = try await fetchUsage(from: url, accessToken: accessToken)
                    if snapshot.creditsUsedPercent != nil || snapshot.resetsAt != nil {
                        log.info("Successfully fetched Grok credits from \(urlString)")
                        return snapshot
                    }
                } catch {
                    log.debug("Grok credits request to \(urlString) failed: \(error.localizedDescription)")
                }
            }
        }

        throw GrokCreditsProbeError.commandFailed("No Grok usage endpoint responded with credits data")
    }

    private static func fetchUsage(from url: URL, accessToken: String) async throws -> GrokCreditsSnapshot {
        // Try GET first (most billing endpoints are GET)
        var snapshot = try? await performRequest(url: url, accessToken: accessToken, method: "GET")
        if snapshot != nil {
            return snapshot!
        }

        // Some billing endpoints may expect POST
        snapshot = try? await performRequest(url: url, accessToken: accessToken, method: "POST")
        if let s = snapshot { return s }

        throw GrokCreditsProbeError.commandFailed("All attempts failed for \(url)")
    }

    private static func performRequest(url: URL, accessToken: String, method: String) async throws -> GrokCreditsSnapshot {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GrokCreditsProbeError.commandFailed("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GrokCreditsProbeError.commandFailed("HTTP \(httpResponse.statusCode): \(body)")
        }

        return try parseUsageResponse(data: data)
    }

    private static func parseUsageResponse(data: Data) throws -> GrokCreditsSnapshot {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GrokCreditsProbeError.parseFailed("Invalid JSON")
        }

        // Unwrap common wrappers the backend may use
        let root: [String: Any] = (json["result"] as? [String: Any]) ??
                                  (json["data"] as? [String: Any]) ??
                                  (json["billing"] as? [String: Any]) ??
                                  json

        var creditsUsedPercent: Double?
        var resetsAt: Date?
        var resetDescription: String?
        var payAsYouGoEnabled = false

        // === BillingPeriodUsage shape (from CLI binary strings) ===
        // { monthlyLimit, onDemandCap, billingPeriodStart, billingPeriodEnd, credits: {...}, ... }
        if let monthlyLimit = root["monthlyLimit"] as? Double ?? root["monthly_limit"] as? Double,
           let used = extractCreditsUsed(from: root) {
            if monthlyLimit > 0 {
                creditsUsedPercent = (used / monthlyLimit) * 100
            }
        }

        if let periodEnd = root["billingPeriodEnd"] as? String ??
                           root["billing_period_end"] as? String ??
                           root["periodEnd"] as? String {
            resetDescription = periodEnd
            resetsAt = parseDate(periodEnd)
        }

        // onDemand / pay-as-you-go
        if let onDemand = root["onDemandCap"] as? Double ?? root["on_demand_cap"] as? Double {
            payAsYouGoEnabled = onDemand > 0
        }
        if let onDemandEnabled = root["on_demand_enabled"] as? Bool ?? root["onDemandEnabled"] as? Bool {
            payAsYouGoEnabled = onDemandEnabled
        }

        // === Common alternative shapes ===
        // { "credits": { "used": 5, "total": 100, "percent": 5 } }
        if let credits = root["credits"] as? [String: Any] {
            if let percent = credits["percent"] as? Double ?? credits["usedPercent"] as? Double {
                creditsUsedPercent = percent
            } else if let used = credits["used"] as? Double,
                      let total = credits["total"] as? Double, total > 0 {
                creditsUsedPercent = (used / total) * 100
            }
            if creditsUsedPercent == nil, let used = extractCreditsUsed(from: credits) {
                // fallback if only "used" is present
                creditsUsedPercent = used
            }
        }

        // { "usage": { "credits_used_percent": 5.0 } }
        if let usage = root["usage"] as? [String: Any],
           let percent = usage["credits_used_percent"] as? Double ?? usage["creditsUsedPercent"] as? Double {
            creditsUsedPercent = percent
        }

        // Direct top-level fields
        if creditsUsedPercent == nil {
            if let percent = root["credits_used_percent"] as? Double ?? root["creditsUsedPercent"] as? Double {
                creditsUsedPercent = percent
            } else if let used = root["creditsUsed"] as? Double ?? root["used"] as? Double,
                      let total = root["creditsTotal"] as? Double ?? root["total"] as? Double, total > 0 {
                creditsUsedPercent = (used / total) * 100
            }
        }

        // Reset / billing period dates
        if resetsAt == nil {
            if let reset = root["reset_at"] as? String ?? root["resets_at"] as? String ?? root["resetAt"] as? String {
                resetDescription = reset
                resetsAt = parseDate(reset)
            }
        }

        // Pay as you go
        if !payAsYouGoEnabled {
            if let payGo = root["pay_as_you_go"] as? Bool ?? root["payAsYouGo"] as? Bool {
                payAsYouGoEnabled = payGo
            } else if let payGoStr = root["pay_as_you_go"] as? String ?? root["payAsYouGo"] as? String {
                payAsYouGoEnabled = payGoStr.lowercased().contains("enable")
            }
        }

        // Final fallback: if the CLI prints "Credits used: 5%" somewhere in a wrapped response
        if creditsUsedPercent == nil,
           let raw = String(data: data, encoding: .utf8)?.lowercased(),
           let range = raw.range(of: "credits used:") {
            let after = raw[range.upperBound...]
            if let pctRange = after.range(of: "%"),
               let val = Double(String(after[..<pctRange.lowerBound]).trimmingCharacters(in: .whitespaces)) {
                creditsUsedPercent = val
            }
        }

        return GrokCreditsSnapshot(
            creditsUsedPercent: creditsUsedPercent,
            resetsAt: resetsAt,
            resetDescription: resetDescription,
            payAsYouGoEnabled: payAsYouGoEnabled
        )
    }

    private static func extractCreditsUsed(from dict: [String: Any]) -> Double? {
        if let v = dict["used"] as? Double { return v }
        if let v = dict["creditsUsed"] as? Double { return v }
        if let v = dict["credits_used"] as? Double { return v }
        if let v = dict["current"] as? Double { return v }
        return nil
    }

    private static func parseDate(_ str: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: str) { return d }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Los_Angeles")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd HH:mm", "MMM d, h:mm a", "MMMM d, h:mm a zzz"] {
            formatter.dateFormat = fmt
            if let d = formatter.date(from: str) { return d }
        }
        return nil
    }

    // MARK: - Real gRPC-web endpoint (discovered via browser)

    private static func fetchGrokBuildBillingCreditsConfig(accessToken: String) async throws -> GrokCreditsSnapshot {
        guard let url = URL(string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig") else {
            throw GrokCreditsProbeError.commandFailed("Invalid gRPC URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "x-grpc-web")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        // Minimal gRPC-web unary request (no input message for GetGrokCreditsConfig)
        let grpcBody: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00] // compressed=0, message length=0
        request.httpBody = Data(grpcBody)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GrokCreditsProbeError.commandFailed("Invalid gRPC response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            appendDebugLog("gRPC call failed with status \(httpResponse.statusCode): \(body)")
            throw GrokCreditsProbeError.commandFailed("gRPC HTTP \(httpResponse.statusCode): \(body)")
        }

        let protobufPayload = extractProtobufPayload(from: data)
        if protobufPayload.isEmpty {
            throw GrokCreditsProbeError.commandFailed("Empty protobuf payload from gRPC response")
        }

        log.debug("gRPC GetGrokCreditsConfig returned \(protobufPayload.count) bytes of protobuf data")

        // === TEMPORARY DEBUG LOGGING ===
        // Copy the line below and paste it somewhere safe when you see it in the logs.
        let hex = protobufPayload.map { String(format: "%02x", $0) }.joined()
        log.info("RAW PROTOBUF HEX (copy this): \(hex)")

        // Feed the Debug pane (Probe logs → Grok)
        appendDebugLog("=== GetGrokCreditsConfig Response ===")
        appendDebugLog("Response size: \(protobufPayload.count) bytes")
        appendDebugLog("RAW HEX:\n\(hex)")

        let snapshot = try parseGrokCreditsConfigProtobuf(protobufPayload)
        appendDebugLog("Parsed result → used: \(snapshot.creditsUsedPercent?.description ?? "nil")%, resets: \(snapshot.resetDescription ?? "nil")")
        return snapshot
    }

    /// Strips gRPC-web framing and returns the raw protobuf message bytes.
    private static func extractProtobufPayload(from grpcWebData: Data) -> Data {
        guard grpcWebData.count > 5 else { return Data() }

        // gRPC-web frame: [flag (1 byte)] [length (4 bytes big-endian)] [message]
        let flag = grpcWebData[0]
        if flag != 0x00 { return Data() } // only handle uncompressed data frame for now

        let length = (Int(grpcWebData[1]) << 24) |
                     (Int(grpcWebData[2]) << 16) |
                     (Int(grpcWebData[3]) << 8)  |
                     (Int(grpcWebData[4]))

        let start = 5
        let end = min(start + length, grpcWebData.count)
        return grpcWebData.subdata(in: start..<end)
    }

    /// Parser for the GetGrokCreditsConfig gRPC response (BillingPeriodUsage protobuf).
    private static func parseGrokCreditsConfigProtobuf(_ data: Data) throws -> GrokCreditsSnapshot {
        var creditsUsedPercent: Double?
        var resetsAt: Date?
        var resetDescription: String?
        var payAsYouGoEnabled = false

        let bytes = [UInt8](data)

        // === 1. Extract usage percentage ===
        // The usage value is the first fixed32 (wire type 5, field 1) after the length-delimited wrapper.
        // It appears as `0d <4 bytes float32 little-endian>`.
        for i in 0..<(bytes.count - 4) {
            if bytes[i] == 0x0d {
                let bitPattern = UInt32(bytes[i + 1]) |
                                 (UInt32(bytes[i + 2]) << 8) |
                                 (UInt32(bytes[i + 3]) << 16) |
                                 (UInt32(bytes[i + 4]) << 24)
                let floatValue = Float(bitPattern: bitPattern)
                if floatValue >= 0 && floatValue <= 100 {
                    creditsUsedPercent = Double(floatValue)
                    break
                }
            }
        }

        // === 2. Extract reset date (billingPeriodEnd) ===
        // Field 4 (22 06) = billingPeriodStart
        // Field 5 (2a 06) = billingPeriodEnd  ← we specifically want this one
        var index = 0
        while index < bytes.count - 6 {
            if bytes[index] == 0x2a && bytes[index + 1] == 0x06 && bytes[index + 2] == 0x08 {
                // This is billingPeriodEnd
                index += 3
                var value: UInt64 = 0
                var shift = 0
                var pos = index
                while pos < bytes.count {
                    let b = bytes[pos]
                    value |= UInt64(b & 0x7F) << shift
                    shift += 7
                    pos += 1
                    if (b & 0x80) == 0 { break }
                }
                if value > 1_600_000_000 {
                    resetsAt = Date(timeIntervalSince1970: TimeInterval(value))
                    let formatter = DateFormatter()
                    formatter.dateStyle = .medium
                    resetDescription = formatter.string(from: resetsAt!)
                }
                index = pos
            } else if bytes[index] == 0x22 && bytes[index + 1] == 0x06 && bytes[index + 2] == 0x08 {
                // billingPeriodStart (we ignore it for the reset date)
                index += 3
                var value: UInt64 = 0
                var shift = 0
                var pos = index
                while pos < bytes.count {
                    let b = bytes[pos]
                    value |= UInt64(b & 0x7F) << shift
                    shift += 7
                    pos += 1
                    if (b & 0x80) == 0 { break }
                }
                index = pos
            } else {
                index += 1
            }
        }

        return GrokCreditsSnapshot(
            creditsUsedPercent: creditsUsedPercent,
            resetsAt: resetsAt,
            resetDescription: resetDescription,
            payAsYouGoEnabled: payAsYouGoEnabled
        )
    }
}
