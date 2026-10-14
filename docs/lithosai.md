---
summary: "LithosAI prepaid balance and console session authentication."
provider_id: lithosai
provider_name: LithosAI
provider_source: Browser or manual console cookies for prepaid USD balance and optional UTC spend.
plugin_scope: Opaque session cookies with same-origin host CSRF echo; active-organization balance and optional spend on both engines.
read_when:
  - Configuring LithosAI
  - Debugging LithosAI console usage
---

# LithosAI

Enable LithosAI in Settings → Providers. Sign in at <https://console.lithosai.cloud> in a supported browser and use the
**Refresh** beside **Cookie source** (or the menu's Refresh action) to authorize importing the session.
An explicit refresh allows one bounded macOS Keychain permission retry; scheduled refreshes never prompt.
If browser access is suppressed or denied, the error points back to Cookie source → Refresh and the Manual fallback.
Automatic import follows the shared browser order and access gate. Alternatively choose Manual and paste a Cookie request header containing
both `__Host-console_session` and `__Host-console_csrf` from the same signed-in console session. Manual cookies
are stored in the CodexBar config file. Inference API keys cannot read console billing.

The bundled plugin shows the active organization's prepaid USD balance, payment-card state, account hold state,
and optional today/month-to-date spend in UTC. Money fields use **1 USD = 1,000,000,000 nanos**. Sparse spend rows
are summed across models and keys; a successful empty report means zero spend. An unavailable or malformed spend
report leaves the balance visible and labels spend unavailable. There is no invented quota percentage, budget,
or reset date. Negative balances remain visible, and positive amounts below one cent are labeled explicitly.
With Icon & percent, the automatic numeric value is this same formatted balance (for example, `L $2.57`).
The explicit **Balance** layout token also uses it, including when LithosAI is selected in merged mode.
Zero, negative, and sub-cent values retain the dropdown formatting.

Read-only console GETs:

- `/api/me` supplies the user and active organization.
- `/api/billing` supplies `balanceNanos`, `hasCard`, and `onHold`.
- `/api/billing/spend?start=YYYY-MM-DD&end=YYYY-MM-DD` supplies the inclusive UTC month-to-date range.

Billing requests echo the active organization ID as `X-Organization-Id`. The host, not the script, echoes
`__Host-console_csrf` as `X-Console-Csrf` from the selected session and only on the declared HTTPS console origin.
Cookie values remain opaque to JavaScript. Both cookies must match the request URL; no persistent session cache
is added; a validated refresh succeeds without requiring a persistent cookie write. HTTP 401 rejects that session and tries the next profile; 403 reports denied access without evicting it.

CLI: `codexbar usage --provider lithosai --source web --json`. On Linux use a manual cookie header in the config;
automatic browser import is macOS-only. No API key or separate login command is needed.

The undocumented console contract was documented by @apoorvdarshan in
[#3868](https://github.com/steipete/CodexBar/issues/3868). Their
[reference client](https://github.com/apoorvdarshan/lithosai-bar) was consulted for protocol semantics;
CodexBar implements its own plugin and uses synthetic fixtures, without importing the client's code.
