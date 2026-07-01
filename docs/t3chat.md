---
summary: "T3 Chat provider auth, tRPC endpoint, and quota windows."
read_when:
  - Adding or modifying the T3 Chat provider
  - Debugging T3 Chat cookie import or usage parsing
  - Explaining T3 Chat setup
---

# T3 Chat Provider

The T3 Chat provider tracks the 4-hour Base and monthly Overage usage buckets from
[t3.chat](https://t3.chat).

## Setup

### Automatic (recommended)

1. Sign in to T3 Chat in any supported browser.
2. Enable **T3 Chat** in **Settings → Providers**.

CodexBar imports your browser session cookie automatically. CodexBar sends the cookie only to
`https://t3.chat`.

**Note**: Browser cookie import may require Full Disk Access (especially for Safari) or macOS
Keychain approval (for Chromium-based browsers).

### Manual

Set **Cookie source** to **Manual** in the T3 Chat provider settings, then paste either:

- A bare `Cookie: ...` header value copied from a browser network request to `t3.chat`, or
- A full `curl` command captured from the T3 Chat settings page (all `-H` flags are parsed;
  only the `Cookie` header and a fixed set of safe request headers are forwarded).

To capture the cookie manually:

1. Open [t3.chat/settings/customization](https://t3.chat/settings/customization) in your browser.
2. Open Developer Tools → Network tab.
3. Reload the page and find a `getCustomerData` tRPC request.
4. Right-click → Copy → Copy as cURL.
5. Paste the full `curl` command into the **T3 Chat cookie** field in CodexBar settings.

T3 Chat does not support a standalone environment variable or a `--cookie` CLI flag. The only manual path is the Settings field above.

## Data Source

CodexBar sends one GET request per refresh:

```text
GET https://t3.chat/api/trpc/getCustomerData?batch=1&input=...
```

The response is JSONL. CodexBar scans each line for the embedded `getCustomerData` tRPC result
object and decodes it to a `T3ChatCustomerData` struct. No other T3 Chat endpoints are called.

### Fields mapped to usage windows

| Source field | CodexBar label | Notes |
|---|---|---|
| `usageFourHourPercentage` | **Base** (primary) | 4-hour rolling window; 0–100 |
| `usageFourHourNextResetAt` | Base reset time | JavaScript epoch ms or Unix seconds |
| `usageWindowNextResetAt` | Base reset time (fallback) | Used when `usageFourHourNextResetAt` is absent |
| `usageMonthPercentage` | **Overage** (secondary) | Monthly overage window |
| `usagePeriodPercentage` | Overage (fallback) | Used when `usageMonthPercentage` is absent |
| `subscription.currentPeriodEnd` | Overage reset time | Billing period end; absent on some plans |
| `usageBand` | Base label suffix | e.g. `"standard"` appended as "Base - standard" |
| `subTier` / `subscription.productName` | Plan name | Shown as the account identity in the menu |

Timestamps larger than 10 billion are treated as milliseconds; smaller values are treated as Unix
seconds.

## Usage Windows

**Base window (primary)**: 4-hour rolling rate-limit bucket. Tracks the percentage of the hourly
model-generation allowance consumed since the window opened. Resets approximately every 4 hours on
T3 Chat's server clock.

**Overage window (secondary)**: Monthly overage budget. Tracks spend beyond the included plan
allowance. Reset timing comes from the active subscription's current-period end; if no subscription
metadata is present, the reset time is shown as unknown.

## CLI

```bash
# Show T3 Chat usage
codexbar usage --provider t3chat

# Or use the alias
codexbar usage --provider t3-chat
codexbar usage --provider t3
```

T3 Chat provides no token-cost data. The `usage --format json` output contains usage and identity
data, while `codexbar cost --provider t3chat` is unsupported.

## Common errors

| Error | Cause | Fix |
|---|---|---|
| `No T3 Chat cookies found` | No browser session for `t3.chat` | Sign in to T3 Chat in a supported browser and try automatic mode |
| `T3 Chat session cookie is invalid or expired` | Stale or revoked session cookie | Sign out of T3 Chat, sign back in, then refresh CodexBar or repaste the cookie |
| `T3 Chat returned a Vercel security challenge` | Manual Cookie header was used but T3 Chat requires additional Vercel request headers | Paste a full `curl` capture instead of a bare Cookie header |
| `Could not parse T3 Chat usage` | T3 Chat changed its tRPC response shape | Open a CodexBar issue with a redacted response sample |
| `HTTP 401` / `HTTP 403` | Session expired or account not found | Re-authenticate |
| `HTTP 429` with `x-vercel-mitigated: challenge` | Rate-limited by Vercel edge | Wait a few minutes, then retry with a full cURL capture |

## Key files

- `Sources/CodexBarCore/Providers/T3Chat/T3ChatProviderDescriptor.swift` — provider metadata and fetch pipeline
- `Sources/CodexBarCore/Providers/T3Chat/T3ChatUsageFetcher.swift` — tRPC request, cookie import, and cURL parsing
- `Sources/CodexBarCore/Providers/T3Chat/T3ChatUsageSnapshot.swift` — response decoding and window mapping
- `Sources/CodexBar/Providers/T3Chat/T3ChatProviderImplementation.swift` — settings pickers and bindings
- `Sources/CodexBar/Providers/T3Chat/T3ChatSettingsStore.swift` — cookie source and header persistence
