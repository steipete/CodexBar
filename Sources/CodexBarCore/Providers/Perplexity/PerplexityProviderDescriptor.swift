import CodexBarMacroSupport
import Foundation
import Security

// MARK: - Descriptor

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum PerplexityProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .perplexity,
            metadata: ProviderMetadata(
                id: .perplexity,
                displayName: "Perplexity",
                sessionLabel: "Credits",
                weeklyLabel: "Usage",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: true,
                creditsHint: "Pro/Max credit balance from perplexity.ai.",
                toggleTitle: "Show Perplexity usage",
                cliName: "perplexity",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://www.perplexity.ai/settings/account",
                subscriptionDashboardURL: "https://www.perplexity.ai/settings/account",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .perplexity,
                iconResourceName: "ProviderIcon-perplexity",
                color: ProviderColor(red: 32 / 255, green: 219 / 255, blue: 204 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Perplexity cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [PerplexityWebFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "perplexity",
                versionDetector: nil))
    }
}

// MARK: - Keychain helpers

public enum PerplexityKeychainStore {
    static let service = "com.codexbarrt.perplexity"
    static let account = "session-cookie"

    public static func readCookie() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let cookie = String(data: data, encoding: .utf8),
              !cookie.isEmpty
        else { return nil }
        return cookie
    }

    public static func writeCookie(_ cookie: String) throws {
        let data = Data(cookie.utf8)
        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            throw PerplexityError.keychainWriteFailed(status)
        }
    }

    public static func clearCookie() {
        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
    }
}

// MARK: - Errors

public enum PerplexityError: LocalizedError, Sendable {
    case notConfigured
    case invalidResponse
    case httpError(Int, retryAfter: TimeInterval?)
    case keychainWriteFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Perplexity session cookie not configured. Open Settings → Perplexity to add your cookie."
        case .invalidResponse:
            return "Unexpected response from Perplexity — the API format may have changed."
        case let .httpError(code, retryAfter):
            if let retryAfter {
                return "Perplexity API returned HTTP \(code). Retry after \(Int(retryAfter.rounded()))s."
            }
            return "Perplexity API returned HTTP \(code). Your session cookie may be expired."
        case let .keychainWriteFailed(status):
            return "Failed to save Perplexity cookie to Keychain (OSStatus \(status))."
        }
    }
}

// MARK: - Fetch strategy

struct PerplexityWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "perplexity.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        PerplexityKeychainStore.readCookie() != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let cookie = PerplexityKeychainStore.readCookie() else {
            throw PerplexityError.notConfigured
        }

        var request = URLRequest(
            url: URL(string: "https://www.perplexity.ai/rest/user/settings")!,
            timeoutInterval: context.webTimeout)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw PerplexityError.httpError(http.statusCode, retryAfter: Self.retryAfter(from: http))
        }

        let usage = try Self.parse(data: data)
        return self.makeResult(usage: usage, sourceLabel: "web")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func parse(data: Data) throws -> UsageSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PerplexityError.invalidResponse
        }

        // Credit fields vary by plan tier; try multiple key paths.
        let creditsRemaining = json["remaining_credits"] as? Double
            ?? json["credits_remaining"] as? Double
        let creditsTotal = json["total_credits"] as? Double
            ?? json["credits_total"] as? Double

        let usedPercent: Double
        if let remaining = creditsRemaining, let total = creditsTotal, total > 0 {
            usedPercent = max(0, min(100, (1.0 - (remaining / total)) * 100))
        } else {
            usedPercent = 0
        }

        let resetAt: Date? = {
            guard let raw = json["credits_reset_at"] as? String ?? json["reset_at"] as? String else { return nil }
            return ISO8601DateFormatter().date(from: raw)
        }()

        let primary = RateWindow(
            usedPercent: usedPercent,
            windowMinutes: nil,
            resetsAt: resetAt,
            resetDescription: nil)

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(),
            identity: nil)
    }

    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            return nil
        }

        if let seconds = TimeInterval(raw), seconds >= 0 {
            return seconds
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
}
