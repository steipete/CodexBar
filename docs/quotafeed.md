---
summary: "Read a user-selected local JSON quota feed without accessing accounts or running commands."
read_when:
  - Connecting a local quota exporter
  - Debugging Quota Feed freshness or validation errors
provider_id: quotafeed
provider_name: Quota Feed
provider_source: Explicit local JSON file; no account access or network requests
provider_runtime: native
plugin_scope: Native bounded local file reader
---

# Quota Feed

Quota Feed displays a quota exported by a tool you control. It is disabled by default and has no built-in
service integration, browser access, credentials, network requests, or command execution. Your exporter remains
separate from CodexBar and is responsible for obtaining data through a source you are authorized to use.

## Setup

1. Write a regular UTF-8 JSON file using the schema below. Use an absolute path.
2. Enable **Quota Feed** in Settings → Providers and enter that path under **File**.
3. Update the file at least every 15 minutes. CodexBar reads it on its normal refresh schedule.

For CLI use, set `quotaFeedPath` in the `quotafeed` entry of your CodexBar config:

```json
{"id":"quotafeed","enabled":true,"quotaFeedPath":"/absolute/path/to/quota.json"}
```

Then run `codexbar usage --provider quotafeed --source cli`. The source label is **local file** in both hosts.
The path is stored in the local config. No default path, home-directory discovery, environment expansion, shell
expansion, or fallback account is used. Multiple independent feeds are not supported in this initial integration.

## Version 1 format

This example is synthetic. Replace `observedAt` with the actual time the exporter observed the quota before trying it:

```json
{
  "version": 1,
  "observedAt": "2026-01-01T12:00:00Z",
  "used": 25,
  "limit": 100,
  "currency": "USD",
  "resetsAt": "2026-02-01T00:00:00Z"
}
```

- `version`: exactly `1`.
- `observedAt`: required ISO-8601 timestamp, including a time zone, at whole-second precision. This is the source
  observation time, not the time a stale cached value was copied into the file.
- `used` and `limit`: required finite, nonnegative numbers. Overage is preserved. A zero limit displays amounts
  without inventing a percentage. Both numbers must use the same unit.
- `currency`: optional three-letter uppercase currency code. Omit it for tokens, requests, or generic credits.
- `resetsAt`: optional ISO-8601 timestamp at whole-second precision. Omit it if the source does not report a reset.

Only these keys are accepted. Do not include identity, tokens, cookies, URLs, or raw service responses.
The shared quota display respects the user's used/remaining preference. Details show Used, Limit, and Remaining;
monetary feeds also supply the standard cost snapshot. Negative remaining amounts indicate overage, not a parsing error.
No monthly duration or reset date is inferred. The displayed update time remains the original observation time.

## Freshness and file access

A feed older than 15 minutes, more than 60 seconds in the future, or past its reported reset is rejected. A read or
validation failure uses CodexBar's normal failed-refresh state; it never turns into a successful zero balance or stamps
an old observation as fresh.

Reads are bounded to 64 KiB, and only regular files are accepted. The final path must not be a symlink; directories,
FIFOs, sockets, and devices are rejected without blocking. Write a temporary file in the same directory and rename it
atomically over the configured path to avoid partial reads. Errors do not include file paths or raw JSON.

The feed is local, but its normalized quota becomes ordinary CodexBar usage data. Existing user-enabled history,
exports, hooks, widgets, or sharing features may consume it. Export only values you are permitted to expose to those
features; this adapter does not change their policies or grant permission to disclose third-party data.
