---
summary: "Zed provider data sources: editor Keychain session and Zed cloud API for plan and edit-prediction quota."
read_when:
  - Debugging Zed usage fetch
  - Updating Zed Keychain or cloud API handling
  - Adjusting Zed provider UI/menu behavior
---

# Zed provider

CodexBar monitors Zed plan status, billing cycle dates, edit-prediction quota, and billing warnings via Zed’s internal cloud API. Live **Zed-hosted token-dollar spend** is **not** available through that API — see [Plans & Pricing](https://zed.dev/docs/account/plans-and-pricing.html).

## Data source

**Local probe (Keychain + cloud API)** — reads the same credentials Zed stores after GitHub sign-in, then calls:

```text
GET https://cloud.zed.dev/client/users/me
Authorization: {user_id} {access_token}
```

### Keychain credentials

| Item | Value |
| --- | --- |
| Service URL | `https://zed.dev` by default, or custom `credentials_url` from `~/Library/Application Support/Zed/settings.json` |
| Keychain class | **Internet password** (`kSecClassInternetPassword`, server = service URL). Generic-password fallback is supported for older layouts. |
| Account | Zed user ID (string) |
| Secret | Access token (UTF-8 bytes) |

CodexBar uses `KeychainNoUIQuery` for non-interactive reads. If Zed has never been signed in, or CodexBar lacks Keychain access, the provider reports **Not signed in to Zed**.

### Settings override

Zed’s `credentials_url` setting (falls back to `server_url`) selects which Keychain entry to read. This supports side-by-side Zed installs with different user data directories.

## Snapshot mapping

| Zed field | CodexBar display |
| --- | --- |
| `plan.plan_v3` | Plan label (Free / Pro / Trial / Student / Business) |
| `plan.usage.edit_predictions` | Primary bar: used/limit or “Unlimited” on Pro+ |
| `plan.subscription_period.ended_at` | Billing cycle reset / secondary window |
| Included token credits (docs) | Static note: Pro $5, Student $10, Trial $20 — **not live spend** |
| `plan.has_overdue_invoices` | Warning note + billing window marker |

Menu footnote: **Token spend: see dashboard.zed.dev billing page**.

## Limitations

### Token credits (Orb billing)

Zed documents that hosted-model token usage lives on [dashboard.zed.dev](https://dashboard.zed.dev) via an Orb embed — there is **no public billing API**. CodexBar does **not** scrape Orb in Phase 1.

- Pro / Student / Trial included amounts are **static labels** from [Plans & Pricing](https://zed.dev/docs/account/plans-and-pricing.html).
- For live dollar consumption and spend limits, open the dashboard billing page.

### Not tracked as “Zed”

Per [LLM Providers](https://zed.dev/docs/ai/llm-providers.html) and [External Agents](https://zed.dev/docs/ai/external-agents.html):

- BYOK models → track via OpenAI, Claude, Gemini, etc.
- External agents (Claude Agent, Codex ACP) → bill through those providers

### Undocumented client API

`/client/users/me` is Zed’s editor API, not a published integration surface. Response shapes may change (`plan_v3` versioning exists for this reason).

## Troubleshooting

### “Not signed in to Zed”
- Sign in from the **Zed editor app** (Command Palette → `client: sign in`), not only dashboard.zed.dev in a browser.
- Confirm a Keychain internet-password entry exists for server `https://zed.dev` (or your custom `credentials_url`).

### “Could not read Zed credentials from the Keychain”
- macOS may block Keychain access until you allow CodexBar (same class of issue as other IDE probes).
- Re-sign in to Zed after changing `credentials_url`.

### Plan matches Zed but token spend differs
- Expected: token meters are dashboard-only. Use **Open dashboard** from the menu card.

## Key files

- `Sources/CodexBarCore/Providers/Zed/ZedStatusProbe.swift` — Keychain read, HTTP, JSON parse, snapshot mapping
- `Sources/CodexBarCore/Providers/Zed/ZedProviderDescriptor.swift` — fetch strategy
- `Sources/CodexBar/Providers/Zed/ZedProviderImplementation.swift` — settings hooks
- `Tests/CodexBarTests/ZedStatusProbeTests.swift` — fixture-based parser/probe tests
