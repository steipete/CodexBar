---
summary: "Codex OAuth resolver: tokens, refresh, usage endpoint, and fetch strategy wiring."
read_when:
  - Adding or modifying Codex OAuth usage fetching
  - Debugging auth.json parsing or token refresh behavior
  - Adjusting Codex provider source selection
---

# Codex OAuth Resolver Implementation Plan

> Replicate Codex's direct OAuth token usage in CodexBar instead of calling the CLI.

## Background

Currently, CodexBar fetches Codex usage by:
1. Running `codex` CLI in PTY mode
2. Sending `/status` command
3. Parsing the text output

This is slow and unreliable. The goal is to directly read Codex's OAuth tokens and call the same API endpoints that Codex uses internally.

---

## Codex OAuth Architecture (from source analysis)

### Token Storage

**Location:** `~/.codex/auth.json`

```json
{
  "OPENAI_API_KEY": null,
  "tokens": {
    "id_token": "eyJ...",
    "access_token": "eyJ...",
    "refresh_token": "...",
    "account_id": "account-..."
  },
  "last_refresh": "2025-12-28T12:34:56Z"
}
```

**Source:** `codex-rs/core/src/auth/storage.rs`

### Token Refresh

**Endpoint:** `POST https://auth.openai.com/oauth/token`

**Request:**
```json
{
  "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
  "grant_type": "refresh_token",
  "refresh_token": "<refresh_token>",
  "scope": "openid profile email"
}
```

**Response:**
```json
{
  "id_token": "eyJ...",
  "access_token": "eyJ...",
  "refresh_token": "..."
}
```

**Refresh Interval:** 8 days (from `TOKEN_REFRESH_INTERVAL` constant)

**Source:** `codex-rs/core/src/auth.rs:504-545`

### Usage API

**Endpoint:** `GET {chatgpt_base_url}/wham/usage` (default: `https://chatgpt.com/backend-api/wham/usage`)

If `chatgpt_base_url` does not include `/backend-api`, Codex falls back to
`{base_url}/api/codex/usage` (see `PathStyle` in `backend-client/src/client.rs`).

**Headers:**
```
Authorization: Bearer <access_token>
ChatGPT-Account-Id: <account_id>
User-Agent: codex-cli
```

**Quick checks**
- Command: `cat ~/.codex/auth.json`
- Command: `curl -H "Authorization: Bearer <access_token>" -H "ChatGPT-Account-Id: <account_id>" -H "User-Agent: codex-cli" https://chatgpt.com/backend-api/wham/usage`
- Command: `CodexBarCLI usage --provider codex --source oauth --json --pretty`

**Response:**
```json
{
  "plan_type": "pro",
  "rate_limit": {
    "primary_window": {
      "used_percent": 15,
      "reset_at": 1735401600,
      "limit_window_seconds": 18000
    },
    "secondary_window": {
      "used_percent": 5,
      "reset_at": 1735920000,
      "limit_window_seconds": 604800
    }
  },
  "credits": {
    "has_credits": true,
    "unlimited": false,
    "balance": 150.0
  }
}
```

**Source:** `codex-rs/backend-client/src/client.rs:161-170`

---

## Implementation

### Files to Create

| File | Location | Purpose |
|------|----------|---------|
| `CodexOAuthCredentials.swift` | `Sources/CodexBarCore/Providers/Codex/CodexOAuth/` | Token storage model + loader |
| `CodexOAuthUsageFetcher.swift` | `Sources/CodexBarCore/Providers/Codex/CodexOAuth/` | API client for usage endpoint |
| `CodexTokenRefresher.swift` | `Sources/CodexBarCore/Providers/Codex/CodexOAuth/` | Token refresh logic |

### Files to Modify

| File | Changes |
|------|---------|
| `CodexProviderDescriptor.swift` | Add `CodexOAuthFetchStrategy`, update `resolveStrategies()` |

---

### Step 1: CodexOAuthCredentials.swift

```swift
import Foundation

public struct CodexOAuthCredentials: Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let idToken: String?
    public let accountId: String?
    public let lastRefresh: Date?

    public var needsRefresh: Bool {
        guard let last = lastRefresh else { return true }
        let eightDays: TimeInterval = 8 * 24 * 3600
        return Date().timeIntervalSince(last) > eightDays
    }
}

public enum CodexOAuthCredentialsError: LocalizedError {
    case notFound
    case decodeFailed(String)
    case missingTokens

    public var errorDescription: String? {
        switch self {
        case .notFound:
            "Codex auth.json not found. Run `codex` to log in."
        case .decodeFailed(let msg):
            "Failed to decode Codex credentials: \(msg)"
        case .missingTokens:
            "Codex auth.json exists but contains no tokens."
        }
    }
}

public enum CodexOAuthCredentialsStore {
    private static var authFilePath: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Respect CODEX_HOME if set
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"],
           !codexHome.isEmpty {
            return URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json")
        }
        return home.appendingPathComponent(".codex/auth.json")
    }

    public static func load() throws -> CodexOAuthCredentials {
        let url = authFilePath
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CodexOAuthCredentialsError.notFound
        }

        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexOAuthCredentialsError.decodeFailed("Invalid JSON")
        }

        // Check for API key auth (no tokens needed for refresh)
        if let apiKey = json["OPENAI_API_KEY"] as? String, !apiKey.isEmpty {
            return CodexOAuthCredentials(
                accessToken: apiKey,
                refreshToken: "",
                idToken: nil,
                accountId: nil,
                lastRefresh: nil)
        }

        guard let tokens = json["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              let refreshToken = tokens["refresh_token"] as? String else {
            throw CodexOAuthCredentialsError.missingTokens
        }

        let idToken = tokens["id_token"] as? String
        let accountId = tokens["account_id"] as? String

        let lastRefresh: Date? = {
            guard let str = json["last_refresh"] as? String else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: str) ?? ISO8601DateFormatter().date(from: str)
        }()

        return CodexOAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accountId: accountId,
            lastRefresh: lastRefresh)
    }

    public static func save(_ credentials: CodexOAuthCredentials) throws {
        let url = authFilePath

        // Read existing file to preserve structure
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        var tokens: [String: Any] = [
            "access_token": credentials.accessToken,
            "refresh_token": credentials.refreshToken
        ]
        if let idToken = credentials.idToken {
            tokens["id_token"] = idToken
        }
        if let accountId = credentials.accountId {
            tokens["account_id"] = accountId
        }

        json["tokens"] = tokens
        json["last_refresh"] = ISO8601DateFormatter().string(from: Date())

        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
```

---

### Step 2: CodexOAuthUsageFetcher.swift

```swift
import Foundation

public struct CodexUsageResponse: Decodable, Sendable {
    public let planType: PlanType
    public let rateLimit: RateLimitDetails?
    public let credits: CreditDetails?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
    }

    public enum PlanType: String, Decodable, Sendable {
        case guest, free, go, plus, pro
        case freeWorkspace = "free_workspace"
        case team, business, education, quorum, k12, enterprise, edu
    }

    public struct RateLimitDetails: Decodable, Sendable {
        public let primaryWindow: WindowSnapshot?
        public let secondaryWindow: WindowSnapshot?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    public struct WindowSnapshot: Decodable, Sendable {
        public let usedPercent: Int
        public let resetAt: Int
        public let limitWindowSeconds: Int

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case limitWindowSeconds = "limit_window_seconds"
        }
    }

    public struct CreditDetails: Decodable, Sendable {
        public let hasCredits: Bool
        public let unlimited: Bool
        public let balance: Double?

        enum CodingKeys: String, CodingKey {
            case hasCredits = "has_credits"
            case unlimited
            case balance
        }
    }
}

public enum CodexOAuthFetchError: LocalizedError, Sendable {
    case unauthorized
    case invalidResponse
    case serverError(Int, String?)
    case networkError(Error)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Codex OAuth token expired or invalid. Run `codex` to re-authenticate."
        case .invalidResponse:
            "Invalid response from Codex usage API."
        case .serverError(let code, let msg):
            "Codex API error \(code): \(msg ?? "unknown")"
        case .networkError(let error):
            "Network error: \(error.localizedDescription)"
        }
    }
}

public enum CodexOAuthUsageFetcher {
    private static let defaultChatGPTBaseURL = "https://chatgpt.com/backend-api/"
    private static let chatGPTUsagePath = "/wham/usage"
    private static let codexUsagePath = "/api/codex/usage"

    public static func fetchUsage(
        accessToken: String,
        accountId: String?
    ) async throws -> CodexUsageResponse {
        var request = URLRequest(url: resolveUsageURL())
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CodexOAuthFetchError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CodexOAuthFetchError.invalidResponse
        }

        switch http.statusCode {
        case 200...299:
            do {
                return try JSONDecoder().decode(CodexUsageResponse.self, from: data)
            } catch {
                throw CodexOAuthFetchError.invalidResponse
            }
        case 401, 403:
            throw CodexOAuthFetchError.unauthorized
        default:
            let body = String(data: data, encoding: .utf8)
            throw CodexOAuthFetchError.serverError(http.statusCode, body)
        }
    }
}
```

---

### Step 3: CodexTokenRefresher.swift

```swift
import Foundation

public enum CodexTokenRefresher {
    private static let refreshEndpoint = URL(string: "https://auth.openai.com/oauth/token")!
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    public enum RefreshError: LocalizedError {
        case expired
        case revoked
        case reused
        case networkError(Error)
        case invalidResponse(String)

        public var errorDescription: String? {
            switch self {
            case .expired:
                "Refresh token expired. Please run `codex` to log in again."
            case .revoked:
                "Refresh token was revoked. Please run `codex` to log in again."
            case .reused:
                "Refresh token was already used. Please run `codex` to log in again."
            case .networkError(let error):
                "Network error during token refresh: \(error.localizedDescription)"
            case .invalidResponse(let msg):
                "Invalid refresh response: \(msg)"
            }
        }
    }

    public static func refresh(_ credentials: CodexOAuthCredentials) async throws -> CodexOAuthCredentials {
        guard !credentials.refreshToken.isEmpty else {
            // API key auth - no refresh needed
            return credentials
        }

        var request = URLRequest(url: refreshEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken,
            "scope": "openid profile email"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw RefreshError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw RefreshError.invalidResponse("No HTTP response")
        }

        if http.statusCode == 401 {
            // Parse error code to classify failure
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorCode = (json["error"] as? [String: Any])?["code"] as? String
                              ?? json["error"] as? String
                              ?? json["code"] as? String {
                switch errorCode.lowercased() {
                case "refresh_token_expired": throw RefreshError.expired
                case "refresh_token_reused": throw RefreshError.reused
                case "refresh_token_invalidated": throw RefreshError.revoked
                default: throw RefreshError.expired
                }
            }
            throw RefreshError.expired
        }

        guard http.statusCode == 200 else {
            throw RefreshError.invalidResponse("Status \(http.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RefreshError.invalidResponse("Invalid JSON")
        }

        let newAccessToken = json["access_token"] as? String ?? credentials.accessToken
        let newRefreshToken = json["refresh_token"] as? String ?? credentials.refreshToken
        let newIdToken = json["id_token"] as? String ?? credentials.idToken

        return CodexOAuthCredentials(
            accessToken: newAccessToken,
            refreshToken: newRefreshToken,
            idToken: newIdToken,
            accountId: credentials.accountId,
            lastRefresh: Date())
    }
}
```

---

### Step 4: Update CodexProviderDescriptor.swift

Add OAuth to `sourceModes` and create new strategy:

```swift
// In makeDescriptor(), update fetchPlan:
fetchPlan: ProviderFetchPlan(
    sourceModes: [.auto, .oauth, .web, .cli],  // Add .oauth
    pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),

// Update resolveStrategies:
private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
    let oauth = CodexOAuthFetchStrategy()
    let cli = CodexCLIUsageStrategy()
    let web = CodexWebDashboardStrategy()

    switch context.sourceMode {
    case .oauth:
        return [oauth]
    case .web:
        return [web]
    case .cli:
        return [cli]
    case .auto:
        // OAuth first (fast), CLI fallback
        if context.runtime == .cli {
            return [web, cli]
        }
        return [oauth, cli]
    }
}

// Add new strategy:
struct CodexOAuthFetchStrategy: ProviderFetchStrategy {
    let id: String = "codex.oauth"
    let kind: ProviderFetchKind = .oauth

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        (try? CodexOAuthCredentialsStore.load()) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        var creds = try CodexOAuthCredentialsStore.load()

        // Refresh if needed (8+ days old)
        if creds.needsRefresh && !creds.refreshToken.isEmpty {
            creds = try await CodexTokenRefresher.refresh(creds)
            try CodexOAuthCredentialsStore.save(creds)
        }

        let usage = try await CodexOAuthUsageFetcher.fetchUsage(
            accessToken: creds.accessToken,
            accountId: creds.accountId)

        return makeResult(
            usage: Self.mapUsage(usage),
            credits: Self.mapCredits(usage.credits),
            sourceLabel: "oauth")
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        // Fallback to CLI on auth errors
        if let fetchError = error as? CodexOAuthFetchError {
            switch fetchError {
            case .unauthorized: return true
            default: return false
            }
        }
        if error is CodexOAuthCredentialsError { return true }
        if error is CodexTokenRefresher.RefreshError { return true }
        return false
    }

    private static func mapUsage(_ response: CodexUsageResponse) -> UsageSnapshot {
        let primary: RateWindow? = response.rateLimit?.primaryWindow.map { window in
            RateWindow(
                usedPercent: Double(window.usedPercent),
                windowMinutes: window.limitWindowSeconds / 60,
                resetsAt: Date(timeIntervalSince1970: TimeInterval(window.resetAt)),
                resetDescription: nil)
        }

        let secondary: RateWindow? = response.rateLimit?.secondaryWindow.map { window in
            RateWindow(
                usedPercent: Double(window.usedPercent),
                windowMinutes: window.limitWindowSeconds / 60,
                resetsAt: Date(timeIntervalSince1970: TimeInterval(window.resetAt)),
                resetDescription: nil)
        }

        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: response.planType.rawValue)

        return UsageSnapshot(
            primary: primary ?? RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: secondary,
            tertiary: nil,
            providerCost: nil,
            updatedAt: Date(),
            identity: identity)
    }

    private static func mapCredits(_ credits: CodexUsageResponse.CreditDetails?) -> CreditsSnapshot? {
        guard let credits else { return nil }
        return CreditsSnapshot(
            hasCredits: credits.hasCredits,
            unlimited: credits.unlimited,
            balance: credits.balance)
    }
}
```

---

## Constants Reference

| Constant | Value | Source |
|----------|-------|--------|
| Client ID | `app_EMoamEEZ73f0CkXaXp7hrann` | `auth.rs:618` |
| Refresh URL | `https://auth.openai.com/oauth/token` | `auth.rs:66` |
| Usage URL | `https://chatgpt.com/backend-api/wham/usage` (default) | `client.rs:163` |
| Token refresh interval | 8 days | `auth.rs:59` |
| Auth file | `~/.codex/auth.json` | `storage.rs` |

---

## Testing

1. Ensure `~/.codex/auth.json` exists (run `codex` to log in first)
2. Run CodexBar with debug logging enabled
3. Verify OAuth strategy is selected and API calls succeed
4. Test token refresh by manually setting `last_refresh` to old date
5. Test fallback by temporarily renaming auth.json

---

## Error Handling

| Error | Behavior |
|-------|----------|
| No auth.json | Fall back to CLI strategy |
| Token expired | Attempt refresh, fall back to CLI on failure |
| Refresh failed | Log error, fall back to CLI |
| API error | Fall back to CLI |
| Network error | Retry with backoff, then fall back |
