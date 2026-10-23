---
summary: "Chatbox AI quotas from a manually supplied License Key."
read_when:
  - Configuring the Chatbox AI provider
  - Checking its public-client API contract and quota mapping
provider_id: chatbox
provider_name: Chatbox AI
provider_source: API token
plugin_scope: Manual License Key; public-client realtime license details
---

# Chatbox AI

Enable Chatbox AI in Settings → Providers, then paste your Chatbox **License Key** into the existing
**API key** field. The CLI also accepts `CHATBOX_LICENSE_KEY`; the saved provider key takes precedence.
This provider uses the standard credential field and storage policy. It does not read the Chatbox
desktop profile, discover account sessions, or activate/deactivate a license. When changing licenses,
update the key in CodexBar. Keep License Keys private: they can authorize AI requests as well as quota reads.
Signing into the Chatbox app does not configure this provider. Account-login users also need a manually
copyable License Key; accounts that do not expose one cannot be connected through this plugin.

## Public-client contract

The bundled plugin follows Chatbox's public client at revision
[`0ac6385ae1ff5bf778777826da3c5edcd55b61b8`](https://github.com/chatboxai/chatbox/commit/0ac6385ae1ff5bf778777826da3c5edcd55b61b8):

- `GET https://api.chatboxai.app/api/license/detail/realtime`.
- `Authorization: <License Key>`, without a `Bearer` prefix.
- The JSON envelope contains `data`, or an `error` object. HTTP failures are classified without exposing response bodies.

Sources: the renderer's
[`getLicenseDetailRealtime`](https://github.com/chatboxai/chatbox/blob/0ac6385ae1ff5bf778777826da3c5edcd55b61b8/src/renderer/packages/remote.ts#L368),
the shared
[`fetchNativeLicenseDetail`](https://github.com/chatboxai/chatbox/blob/0ac6385ae1ff5bf778777826da3c5edcd55b61b8/src/shared/services/native-license.ts#L110),
and the public
[license detail schema](https://github.com/chatboxai/chatbox/blob/0ac6385ae1ff5bf778777826da3c5edcd55b61b8/packages/chatbox-core/src/domain/settings/settings-schema.ts#L241).
These establish the public client's request and data shape, rather than a separately versioned third-party API guarantee.
The plugin does not use `detail/all_status` or infer that its behavior matches the realtime endpoint.

Requests use the existing plugin HTTP broker, its fixed HTTPS origin and redirect restrictions, and a
`Cache-Control: no-store` request header. Keys and response-only license identifiers are not published in snapshots.
Tests use synthetic keys and injected HTTP responses on both plugin engines; live service compatibility is a separate check.

## Quota mapping

The shared UI's existing translated labels are reused across all 23 app catalogs. The descriptor passes translated
recovery guidance through the existing plugin settings context; HTTP errors retain their status codes, and the CLI
uses English when no app localization is installed. No shared settings or error presentation changes are needed.
The detail section shows **remaining / total** counts:

- **Plan**: the `plan` item in `unified_token_usage_details`; this also supplies the primary meter.
- **Credits**: `aggregated_reward_details`, with unexpired non-plan detail items as a fallback.
- **Top-up credits**: `expansion_pack_limit` and `expansion_pack_usage`; this supplies the independent secondary meter.
- **Image Generation**: `image_total_quota` and `image_used_count`.
- **Quota**: the combined `unified_token_limit` and `unified_token_usage` when separate plan counters are absent.

These are compute points and image counts, not monetary balances or raw model token counts. Combined counters already
include rewards and exclude expansion packs, so they are never added to those pools. Empty optional pools are hidden;
exhausted pools remain visible. If all reported allowances are zero, the detail remains `0 / 0` without a usable meter.

Only a positive, unexpired plan with an absent or active status receives a primary meter. Its future
`token_next_refresh_time` is used for reset timing only when it precedes plan expiry; expiry comes from
`token_expire_time` or `expires_at`. Reward, expansion and image pools do not inherit the plan reset.
Reset dates come from the server without inventing daily or fixed monthly durations. Unrecognized license statuses
retain reported details without promising replenishment.

```sh
codexbar usage --provider chatbox --source api --json
```
