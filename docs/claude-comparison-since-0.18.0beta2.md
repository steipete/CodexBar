# Claude Fetch Comparison (`7b79b2d` vs `HEAD`)

This document compares Claude data fetching behavior between:
- Baseline commit: `7b79b2d080c6b00f6c8f52f89ac115f33a7ca8b0`
- Current `HEAD`: `37841489f849567a598d2a8ba601eb6f1228644e`

Focus areas:
- OAuth
- Web
- CLI
- Keychain permission prompts, cooldowns, and re-prompt behavior
- OAuth token fetch/use/refresh behavior

## High-level Changes

- OAuth moved from "load token and fail if expired" to "auto-refresh when expired".
- Claude keychain reads now use stricter non-interactive probes (`kSecUseAuthenticationUIFail`) before any promptable path.
- New Claude keychain prompt cooldown gate: 6-hour suppression after denial.
- New OAuth refresh failure gate:
  - `invalid_grant` => terminal block until auth fingerprint changes.
  - repeated `400/401` (non-`invalid_grant`) => transient exponential backoff (up to 6h).
- Auto-mode availability checks were hardened to avoid interactive prompts where possible.

## OAuth Flow

### OAuth (Before: `7b79b2d`)

```mermaid
flowchart TD
    A["Claude OAuth fetch starts"] --> B["load(environment)"]
    B --> C{"token found?"}
    C -- "no" --> K["OAuth not available / fail"]
    C -- "yes" --> D{"token expired?"}
    D -- "yes" --> E["Fail: token expired (run claude)"]
    D -- "no" --> F{"has user:profile scope?"}
    F -- "no" --> G["Fail: missing scope"]
    F -- "yes" --> H["GET /api/oauth/usage with Bearer access token"]
    H --> I{"HTTP success?"}
    I -- "yes" --> J["Map usage response -> snapshot"]
    I -- "no" --> L["Invalidate cache, surface OAuth error"]
```

### OAuth (Now: `HEAD`)

```mermaid
flowchart TD
    A["Claude OAuth fetch starts"] --> B["hasCachedCredentials?"]
    B --> C{"cached/refreshable creds exist?"}
    C -- "yes" --> D["loadWithAutoRefresh(allowKeychainPrompt=false unless bootstrap needed)"]
    C -- "no" --> E["Gate: should allow keychain prompt now?"]
    E --> F["loadWithAutoRefresh(allowKeychainPrompt=true if gate allows)"]
    D --> G{"expired?"}
    F --> G
    G -- "no" --> H["Use access token directly"]
    G -- "yes" --> I["POST /v1/oauth/token refresh_token grant"]
    I --> J{"Refresh status"}
    J -- "200" --> K["Save refreshed creds to CodexBar keychain cache + memory"]
    J -- "400/401 + invalid_grant" --> L["Record terminal auth failure; block refresh until auth fingerprint changes"]
    J -- "400/401 other" --> M["Record transient failure; exponential backoff"]
    K --> H
    H --> N{"has user:profile scope?"}
    N -- "no" --> O["Fail: missing scope"]
    N -- "yes" --> P["GET /api/oauth/usage with Bearer access token"]
    P --> Q["Map usage response -> snapshot"]
```

### OAuth Token Source Resolution (Now)

```mermaid
flowchart TD
    A["load(...)"] --> B["Environment token (CODEXBAR_CLAUDE_OAUTH_TOKEN)"]
    B -->|miss| C["Memory cache (valid + unexpired)"]
    C -->|miss| D["CodexBar keychain cache: com.steipete.codexbar.cache/oauth.claude"]
    D -->|miss| E["~/.claude/.credentials.json"]
    E -->|miss| F{"allowKeychainPrompt && prompt gate open?"}
    F -- "yes" --> G["Claude keychain service: Claude Code-credentials (promptable fallback)"]
    F -- "no" --> H["Stop without keychain prompt path"]
```

## Web Flow

### Web (Before and Now: core fetch path largely unchanged)

```mermaid
flowchart TD
    A["Claude Web fetch starts"] --> B{"manual cookie header configured?"}
    B -- "yes" --> C["Extract sessionKey from manual header"]
    B -- "no" --> D["Enumerate cookie import candidates"]
    D --> E["Try browser cookie import (claude.ai domain)"]
    E --> F{"sessionKey found?"}
    C --> F
    F -- "no" --> G["Fail: noSessionKeyFound"]
    F -- "yes" --> H["GET organizations + usage endpoints"]
    H --> I["Build web usage snapshot + identity + optional cost extras"]
```

### Web Candidate Filtering + Prompt Implications (Now)

```mermaid
flowchart TD
    A["cookieImportCandidates(...)"] --> B{"browser uses keychain for decryption?"}
    B -- "no (Safari/Firefox/Zen)" --> C["Keep candidate even if keychain disabled"]
    B -- "yes (Chromium family)" --> D{"Keychain disabled?"}
    D -- "yes" --> E["Drop candidate"]
    D -- "no" --> F["Check BrowserCookieAccessGate cooldown"]
    F --> G{"cooldown active?"}
    G -- "yes" --> E
    G -- "no" --> H["Attempt import; on access denied record 6h cooldown"]
```

## CLI Flow

### CLI Fetch Path (Provider Runtime = `.cli`)

```mermaid
flowchart TD
    A["CLI command (provider=claude)"] --> B{"source mode"}
    B -- "auto" --> C["Strategy order: web -> cli"]
    B -- "web" --> D["Web strategy only"]
    B -- "cli" --> E["CLI PTY strategy only"]
    B -- "oauth" --> F["OAuth strategy only"]
    E --> G["ClaudeStatusProbe via PTY session"]
    G --> H["Parse /usage output -> snapshot"]
```

Notes:
- The PTY parsing path itself is functionally stable in this range.
- Claude CLI session environment still scrubs OAuth env overrides and `ANTHROPIC_*` vars before launching the subprocess.

## App Runtime Auto Pipeline (Provider Fetch Plan)

### App Auto Strategy Order (Descriptor Pipeline)

```mermaid
flowchart TD
    A["App runtime source=auto"] --> B["Try OAuth strategy first"]
    B -->|"available + success"| Z["Done"]
    B -->|"unavailable or fallback on error"| C["Try Web strategy"]
    C -->|"success"| Z
    C -->|"unavailable or fallback on error"| D["Try CLI strategy"]
    D -->|"success"| Z
    D -->|"fail"| E["Provider fetch failure"]
```

### Internal `ClaudeUsageFetcher(dataSource:.auto)` Heuristic (Now)

```mermaid
flowchart TD
    A["ClaudeUsageFetcher.loadLatestUsage(dataSource=.auto)"] --> B["Probe OAuth creds non-interactively"]
    B --> C{"usable OAuth creds?"}
    C -- "yes" --> D["Use OAuth path"]
    C -- "no" --> E{"has web session?"}
    E -- "yes" --> F["Use Web path"]
    E -- "no" --> G{"claude binary present?"}
    G -- "yes" --> H["Try CLI PTY, if fails then OAuth"]
    G -- "no" --> I["Fallback to OAuth"]
```

## Keychain Prompt / Re-prompt Behavior

### Claude OAuth Keychain Prompt Gate (Now)

```mermaid
stateDiagram-v2
    [*] --> PromptAllowed
    PromptAllowed --> CooldownBlocked: recordDenied()
    CooldownBlocked --> CooldownBlocked: shouldAllowPrompt() before deniedUntil
    CooldownBlocked --> PromptAllowed: time >= deniedUntil (6h)
```

### OAuth Refresh Failure Gate (Now)

```mermaid
stateDiagram-v2
    [*] --> Open
    Open --> TransientBackoff: recordTransientFailure (400/401 non-invalid_grant)
    TransientBackoff --> Open: cooldown expires
    TransientBackoff --> Open: auth fingerprint changes
    Open --> TerminalBlocked: recordTerminalAuthFailure (invalid_grant)
    TerminalBlocked --> TerminalBlocked: unchanged auth fingerprint
    TerminalBlocked --> Open: auth fingerprint changes
    TransientBackoff --> TerminalBlocked: terminal auth failure observed
    TerminalBlocked --> Open: recordSuccess
```

## Key Differences in Permission Prompt Surfaces

- Before:
  - OAuth availability/load paths could reach Claude keychain access with less strict non-interactive protection.
  - No dedicated Claude OAuth prompt cooldown gate.
  - No terminal-vs-transient refresh failure gate.
- Now:
  - Non-interactive probes are stricter and reused broadly.
  - Promptable Claude keychain access is gated and usually only bootstrap-oriented.
  - Denials cause cooldown suppression to avoid repeated prompts.
  - Refresh failures can suppress repeated attempts until either timeout (transient) or credential change (terminal).

## Related Files

- `/Users/ratulsarna/Developer/staipete/CodexBar/Sources/CodexBarCore/Providers/Claude/ClaudeUsageFetcher.swift`
- `/Users/ratulsarna/Developer/staipete/CodexBar/Sources/CodexBarCore/Providers/Claude/ClaudeProviderDescriptor.swift`
- `/Users/ratulsarna/Developer/staipete/CodexBar/Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthCredentials.swift`
- `/Users/ratulsarna/Developer/staipete/CodexBar/Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthKeychainAccessGate.swift`
- `/Users/ratulsarna/Developer/staipete/CodexBar/Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthRefreshFailureGate.swift`
- `/Users/ratulsarna/Developer/staipete/CodexBar/Sources/CodexBarCore/KeychainAccessPreflight.swift`
- `/Users/ratulsarna/Developer/staipete/CodexBar/Sources/CodexBarCore/KeychainNoUIQuery.swift`
- `/Users/ratulsarna/Developer/staipete/CodexBar/Sources/CodexBarCore/BrowserCookieImportOrder.swift`
- `/Users/ratulsarna/Developer/staipete/CodexBar/Sources/CodexBarCore/BrowserCookieAccessGate.swift`
