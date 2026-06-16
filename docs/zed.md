---
summary: "Zed provider data source: editor Keychain session and Zed cloud API."
read_when:
  - Debugging Zed usage fetch
  - Updating Zed Keychain or cloud API handling
  - Adjusting Zed provider UI/menu behavior
---

# Zed provider

CodexBar monitors Zed plan status, billing cycle dates, edit-prediction quota, and overdue invoices via Zed's cloud API.

## Data source

**Local probe (Keychain + cloud API)** — reads the same credentials Zed stores after GitHub sign-in, then calls:

```text
GET https://cloud.zed.dev/client/users/me
Authorization: {user_id} {access_token}
```

### Keychain credentials

| Item | Value |
| --- | --- |
| Service URL | `https://zed.dev` by default, or the configured HTTPS `server_url` for a custom server |
| Keychain class | **Internet password** (`kSecClassInternetPassword`, server = service URL). Generic-password fallback is supported for older layouts. |
| Account | Zed user ID (string) |
| Secret | Access token (UTF-8 bytes) |

CodexBar uses `KeychainNoUIQuery` for non-interactive reads. If Zed has never been signed in, or CodexBar lacks Keychain access, the provider reports **Not signed in to Zed**.

### Settings override

CodexBar reads Zed’s user settings from `~/.config/zed/settings.json`. The `credentials_url` setting (falls back to
`server_url`) selects which Keychain entry to read. For the trusted
`https://zed.dev` and `https://staging.zed.dev` servers, Zed may use a separate credential identifier. Custom servers
must use HTTPS and store credentials under the exact same `server_url`; CodexBar rejects cross-origin overrides so a
settings-file change cannot forward a Keychain token to another host.

## Snapshot mapping

| Zed field | CodexBar display |
| --- | --- |
| `plan.plan_v3` | Plan label (Free / Pro / Trial / Student / Business) |
| `plan.usage.edit_predictions` | Primary bar: used/limit or “Unlimited” on Pro+ |
| `plan.subscription_period.ended_at` | Billing cycle reset / secondary window |
| `plan.has_overdue_invoices` | Warning note + billing window marker |

## Limitations

### Not tracked as “Zed”

Per [LLM Providers](https://zed.dev/docs/ai/llm-providers.html) and [External Agents](https://zed.dev/docs/ai/external-agents.html):

- BYOK models → track via OpenAI, Claude, Gemini, etc.
- External agents (Claude Agent, Codex ACP) → bill through those providers

## Troubleshooting

### “Not signed in to Zed”
- Sign in from the **Zed editor app** (Command Palette → `client: sign in`).
- Confirm a Keychain internet-password entry exists for server `https://zed.dev` (or your custom `credentials_url`).

### “Could not read Zed credentials from the Keychain”
- macOS may block Keychain access until you allow CodexBar (same class of issue as other IDE probes).
- Re-sign in to Zed after changing `credentials_url`.

## Key files

- `Sources/CodexBarCore/Providers/Zed/ZedStatusProbe.swift` - Keychain read, cloud API, snapshot mapping
- `Sources/CodexBarCore/Providers/Zed/ZedProviderDescriptor.swift` - provider metadata and local fetch strategy
- `Sources/CodexBar/Providers/Zed/ZedProviderImplementation.swift` - app registration
- `Tests/CodexBarTests/ZedStatusProbeTests.swift` - cloud API and routing tests
