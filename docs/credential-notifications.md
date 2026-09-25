---
summary: "Opt-in credential-expiry alerts, account-scoped episodes, and shared notification delivery."
read_when:
  - Changing credential notification classification or delivery
  - Investigating repeated sign-in alerts
---

# Credential notifications

Settings → Notifications → **Credential expiry** enables a notification when a provider account needs
sign-in again. It is off by default and applies only to this Mac. macOS notification permissions still apply.
The notification contains the provider name and a generic instruction to open CodexBar; it never includes
an email, account ID, token, or raw provider error. Existing provider-card errors remain available.

Each provider/account gets one alert per failure episode. Repeated refreshes, intervening network/quota
failures, and cached or degraded fallback snapshots do not reset the episode. Only a successful fresh
fetch for the same account permits a new alert. Saved token accounts and Codex/Claude account identities
use their existing refresh ownership boundaries. Claude identity gaps use the stable credential-file fingerprint
already captured by refresh; later account identity is bound to the same episode without an additional credential read.
Sources without any account or credential ownership evidence share a default scope for that provider, so an identity gap does not generate a notification on every refresh. Episodes
are in memory and start fresh when the app restarts. Turning the toggle off suppresses delivery without
forgetting unresolved episodes.

The shared classifier accepts the plugin framework's typed authentication-expired and missing-credential
errors plus native credential errors for Codex, Claude, Kimi, Doubao, Alibaba Token Plan, and Augment.
Unknown errors fail closed. Quota/billing exhaustion, permission denial, rate limits, transport failures,
and arbitrary messages containing “token” or “login” are not treated as expired credentials.
Native providers should add a typed mapping or use the shared classified error when adopting this path.

Augment keepalive reports login-required events to the same app path instead of requesting notification
permission or posting independently from the core library. Generic retry exhaustion is not an auth event.
Delivery rechecks consent and episode validity after authorization, and withdraws a request if shutdown,
provider disablement, recovery, or keepalive retirement races with submission. Delivered alerts are also
removed on recovery, provider disablement, keepalive retirement, and app shutdown. Failed or denied delivery releases its reservation
so the next refresh can retry; permission denial is rechecked without repeatedly prompting. This feature does not add
credential reads, refreshes, login flows, or browser imports.

Focused tests use injected power/notification APIs, dictionary defaults, and synthetic fetch outcomes;
they never deliver real notifications or access credentials.
