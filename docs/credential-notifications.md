---
summary: "Opt-in credential-expiry alerts, account-scoped episodes, and shared notification delivery."
read_when:
  - Changing credential notification classification or delivery
  - Investigating repeated sign-in alerts
---

# Credential notifications

Settings → Notifications → **Credential expiry** alerts you when a provider account needs sign-in again. It is off by default, local to this Mac, and subject to macOS notification permissions. Alerts contain only the provider name and an instruction to open CodexBar, never emails, account IDs, tokens, or raw errors. Provider-card errors remain available.

Each provider/account gets one alert per failure episode. Only a successful fresh fetch for that account resets it; repeated refreshes, network/quota failures, and cached or degraded fallback data do not. Episodes reset on app restart. Turning the toggle off suppresses delivery but retains unresolved episodes.

## Delivery contract

Saved token accounts and Codex/Claude identities use their refresh ownership boundaries. During Claude identity gaps, the credential-file fingerprint already captured by refresh identifies the episode; a later account identity joins it without another credential read. Sources with no ownership evidence share one default scope per provider.

The classifier accepts typed plugin authentication-expired/missing-credential errors and native credential errors for Codex, Claude, Kimi, Doubao, Alibaba Token Plan, and Augment. Native providers must add a typed mapping or use the shared classified error. Unknown errors, quota/billing exhaustion, permission denial, rate limits, transport failures, and messages merely containing “token” or “login” do not trigger alerts.

Augment keepalive uses this same delivery path for login-required events; generic retry exhaustion is not an auth event. Delivery rechecks consent and episode validity after authorization. Recovery, provider disablement, keepalive retirement, and shutdown withdraw pending requests and remove delivered alerts. Failed or denied delivery releases its reservation for a later refresh to retry; permission denial is rechecked without repeated prompts. Notifications add no credential reads, refreshes, login flows, or browser imports.

Notification withdrawal runs on a serial background queue, so a stalled response from the system notification service cannot block menu interaction. This includes cleanup after a delivery becomes stale.
