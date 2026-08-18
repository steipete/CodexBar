---
summary: "Codex OAuth resolver: read-only tokens, CLI-owned refresh, usage endpoint, and fetch strategy wiring."
read_when:
  - Adding or modifying Codex OAuth usage fetching
  - Debugging auth.json parsing or token refresh behavior
  - Adjusting Codex provider source selection
---

# Codex OAuth resolver

> Read Codex's OAuth tokens for usage in CodexBar while leaving refresh and persistence to the
> Codex CLI that owns `auth.json`.

## Background

Currently, CodexBar fetches Codex usage by:
1. Running `codex` CLI in PTY mode
2. Sending `/status` command
3. Parsing the text output

This is slow and unreliable. CodexBar now reads OAuth tokens for usage and calls the same API
endpoints that Codex uses internally, while stale native credentials are recovered by the CLI.

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

### Token Freshness and Ownership

Codex CLI owns the refresh endpoint and the refresh-token lifecycle for the native
`CODEX_HOME/auth.json`. CodexBar may inspect `last_refresh` to decide whether a usage snapshot is
stale, but its usage path must not redeem that token or write a replacement file. Instead:

- stale native credentials produce `nativeRefreshRequired` and route to Codex CLI recovery;
- stale legacy/OpenCode credentials produce `readOnlySource` and fail closed because there is no
  safe writer handoff; and
- `CodexTokenRefresher` is not part of the shared-file usage path.

The Codex CLI refresh interval is 8 days (from `TOKEN_REFRESH_INTERVAL`); the source reference is
`codex-rs/core/src/auth.rs:504-545`. The refresh endpoint is documented here for ownership
context only, not as a CodexBar usage action.

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

Use fixture credentials in an isolated `CODEX_HOME` for diagnostics. Do not print the native auth
file or put bearer tokens in shell history. The safe product-level check is
`CodexBarCLI usage --provider codex --source oauth --json --pretty` with an isolated environment.

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
| `CodexTokenRefresher.swift` | `Sources/CodexBarCore/Providers/Codex/CodexOAuth/` | Refresh-error classification and isolated transport tests; not shared-file usage ownership |

### Files to Modify

| File | Changes |
|------|---------|
| `CodexProviderDescriptor.swift` | Add `CodexOAuthFetchStrategy`, update `resolveStrategies()` |

---

### Step 1: CodexOAuthCredentials.swift

The credential store exposes a read-only usage contract:

- `loadForUsage(env:allowExternalSources:)` gives native `CODEX_HOME/auth.json` precedence and
  only considers legacy Codex/OpenCode files when the explicit external-source setting is on.
- Credentials carry their source, freshness, access token, account scope, and refresh metadata;
  account IDs are normalized before JWT fallback is attempted.
- `load()` and `loadOAuthTokens()` are parsing entry points. They do not refresh a token or write a
  file.
- `save(...)` is guarded by the credential source and rejects external files that cannot safely
  persist refresh material. The usage strategy never calls it for shared auth refreshes; native
  `auth.json` refresh remains Codex CLI-owned.
- Missing, malformed, stale-native, and stale-external states remain distinct so the provider can
  choose CLI recovery or a fail-closed error without silently changing credential ownership.

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

The usage path must not call `CodexTokenRefresher.refresh` for a credential loaded from native,
legacy, or OpenCode auth files. The type is retained for refresh-error classification and isolated
transport tests, but ownership is handled as follows:

- `CodexOAuthFetchStrategy` throws `nativeRefreshRequired` for stale native credentials;
- `CodexOAuthNativeRefreshCLIStrategy` delegates that recovery to Codex CLI;
- stale external credentials throw `readOnlySource` and never reach a refresh request; and
- no refresh response is published back to a shared `auth.json` by CodexBar.

---

### Step 4: Update CodexProviderDescriptor.swift

The production strategy is source-aware. Keep the following flow in sync with the provider
implementation instead of copying an OAuth-only fetch example:

1. `CodexOAuthCredentialsStore.loadForUsage` reads the ambient `CODEX_HOME` first. Legacy Codex
   and OpenCode files are considered only when the explicit external-source setting is enabled.
2. `CodexOAuthFetchStrategy` uses that credential snapshot for the usage and reset-credit
   requests. It never redeems or saves a refresh token from the usage path.
3. A stale native snapshot throws `CodexOAuthCredentialsError.nativeRefreshRequired`; the explicit
   OAuth plan routes that state to `CodexOAuthNativeRefreshCLIStrategy`, which delegates recovery
   to Codex CLI. A stale legacy/OpenCode snapshot throws `.readOnlySource` and fails closed because
   there is no safe writer handoff.
4. Auto mode falls back to the CLI only for recoverable native OAuth or credential errors. Stale
   external sources, managed workspace scope, transient API errors, decode failures, and network
   failures remain visible instead of launching an unrelated or unscoped CLI recovery.

The key invariant is that the credential snapshot used for the usage request is also passed to
reset-credit enrichment; reloading `auth.json` after a refresh would reintroduce the shared-file
race this design is intended to avoid.

---

## Constants Reference

| Constant | Value | Source |
|----------|-------|--------|
| Refresh owner | Codex CLI | `auth.rs:66`, `auth.rs:618` |
| Refresh URL | `https://auth.openai.com/oauth/token` (CLI-owned; not a CodexBar usage action) | `auth.rs:66` |
| Usage URL | `https://chatgpt.com/backend-api/wham/usage` (default) | `client.rs:163` |
| Token refresh interval | 8 days | `auth.rs:59` |
| Auth file | `~/.codex/auth.json` | `storage.rs` |

---

## Testing

1. Use fixture files or an isolated `CODEX_HOME`; never test by modifying a real shared auth file.
2. Verify native `CODEX_HOME` precedence and opt-in external-source discovery with
   `CodexOAuthCredentialReadTests`.
3. Verify fresh credentials make usage and reset-credit requests from the same in-memory snapshot.
4. Verify stale native credentials select Codex CLI recovery and stale external credentials fail
   closed without a refresh request or file write.
5. Verify missing, unauthorized, decode, and network errors follow the source-aware fallback
   policy; run `swift test --filter CodexOAuth` and `make check`.

---

## Error Handling

| Error | Behavior |
|-------|----------|
| No native auth file | Auto mode may continue to its next configured strategy; explicit OAuth reports the credential error |
| Stale native credentials | Throw `nativeRefreshRequired` and delegate to Codex CLI; never refresh in-process |
| Stale legacy/OpenCode credentials | Throw `readOnlySource`; fail closed because there is no safe writer handoff |
| Unauthorized OAuth response | Fall back only when the active source mode permits a recoverable CLI strategy |
| Decode, server, or network error | Surface the original error; do not launch unrelated CLI recovery |
