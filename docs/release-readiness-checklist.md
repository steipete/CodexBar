# CodexBarRT Release Readiness Checklist

## Core correctness

- [x] Per-provider scheduler uses completed refresh timestamps, not refresh start timestamps.
- [x] Persisted 429 backoff blocks refreshes after relaunch.
- [x] Global timer uses remaining time until due across providers.
- [x] Claude `3600s` minimum and remote-provider floors are enforced by scheduler math.
- [x] Remote provider rate-limit backoff no longer freezes unrelated providers.
- [x] Gemini file-watcher refreshes respect the same due-time gate as timer-driven refreshes.
- [x] Same-provider refreshes are deduplicated while one is already in flight.

## Error handling

- [x] Claude 429s are surfaced as typed rate-limit errors with optional `Retry-After`.
- [x] Perplexity HTTP errors preserve optional `Retry-After`.
- [x] UsageStore backoff logic uses typed rate-limit detection before string fallback.
- [x] Claude auto mode only forces OAuth fetches when credentials plausibly exist.
- [ ] Decide final product behavior for `Refresh Now` during active 429 backoff.

## Keychain and signing

- [x] Perplexity keychain access is centralized in `CodexBarCore`.
- [x] Perplexity settings writes log failures instead of silently ignoring them.
- [ ] Switch daily development to stable signing via `Scripts/setup_dev_signing.sh`.
- [ ] Verify OAuth/session credentials survive rebuilds with `APP_IDENTITY="CodexBar Development"`.

## Tests

- [x] Add `AdaptiveRefreshScheduler` tests for relaunch backoff, remaining-time math, floors, and force refresh.
- [ ] Add a targeted `UsageStore` test covering duplicate refresh suppression.
- [x] Add a targeted Claude test for the unconfigured-auto-mode path.
- [ ] Add a targeted Perplexity settings test for keychain write/read parity.
- [x] Keep `swift build` clean.
- [x] Keep `swift test` clean.

## Pre-release soak

- [ ] Run a real app session with Codex + Claude + Gemini enabled for at least 30 minutes.
- [ ] Confirm Claude backs off after a forced 429 and recovers after the backoff window expires.
- [ ] Confirm Gemini watcher updates do not trigger rapid remote fetches.
- [ ] Confirm Perplexity cookie persists and fetches after relaunch.
- [ ] Verify stale indicator transitions: `<30s` green, `30s-5m` warning, `>5m/error` red.

## Ship gate

- [ ] No known scheduler correctness bugs remain.
- [ ] No repeated 429 loop on startup after relaunch.
- [ ] No silent keychain write failures in provider settings.
- [ ] Release build signed with stable identity.
- [ ] Final smoke test passes before deploy/notarize.
