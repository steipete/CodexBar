---
summary: "Google Developer Program monthly Gen AI & Cloud credit for Google AI Pro and Ultra, read from the me.developers.google.com benefits page session."
provider_id: googledeveloper
provider_name: Google Developer Program
provider_source: Browser or manual me.developers.google.com session cookies for the current monthly Gen AI & Cloud credit of Google AI Pro and Ultra.
plugin_scope: Opaque Google session cookies, a benefits-page token, and one batchexecute form POST per signed-in account for the current monthly grant on both engines.
read_when:
  - Configuring Google Developer Program credits
  - Debugging the Google Developer Program benefits response
---

# Google Developer Program

Google AI Pro and Ultra include a Google Developer Program premium benefit: a monthly Gen AI & Cloud credit that can
be applied to a Google Cloud billing account (Google AI Pro grants $10 a month, Ultra $40 or $100, in your billing
currency). Each monthly grant stays valid for 12 months; see the [official benefits guide](https://developers.google.com/profile/help/benefits). Google offers no public API for the remaining balance, so
CodexBar reads the same data the benefits page at <https://me.developers.google.com/benefits> shows.

This provider covers only the current monthly grant shown on the benefits page. Older grants that are still valid
are not part of that response, so the balance is not the total credit of the Cloud Billing account. Check
<https://console.cloud.google.com/billing/credits> for every grant.

## Authentication

Enable Google Developer Program in Settings → Providers and sign in at <https://me.developers.google.com>.
Automatic import reads the Google session cookies for `me.developers.google.com` and `google.com` in CodexBar's
default browser order, like the [Gemini app](gemini.md) source. Imports follow the shared browser-access gate: use
**Refresh** beside **Cookie source** (or the menu's Refresh action) to authorize the import. Scheduled refreshes never
prompt, and imported cookies are never written to CodexBar's cookie cache. To keep CodexBar away from browser stores,
choose **Manual** (config: `"cookieSource": "manual"` plus `cookieHeader`) and paste a Cookie request header from a
signed-in me.developers.google.com request. **Off** (`"cookieSource": "off"`) disables cookie access.

A browser can hold several signed-in Google accounts. CodexBar does not ask which one owns the credit. In the first
signed-in browser profile it walks `authuser=0`, `1`, ... and stops when an account index has no signed-in email,
repeats an email already seen, or after eight accounts. The first account whose credit is applied to a billing account
wins. An account whose benefits request returns an RPC error is skipped.

A redirect to accounts.google.com, HTTP 401 or 403, or a benefits page without its page tokens for the first account
rejects that browser session and tries the next profile. When every candidate is rejected, the error asks you to sign
in again.

## Data

These are undocumented endpoints used by the benefits page, so they may change without notice:

- `GET /benefits?authuser=N` returns the page HTML (about 150 KB). CodexBar reads only its XSRF token (`SNlM0e`) and
  signed-in email (`oPEP7c`).
- `POST /_/GoogleDeveloperProfile/data/batchexecute?rpcids=Ro0AYc` sends that token as a form field with the
  benefits page's Origin and Referer. The chunked response is parsed as JSON, and only its `Ro0AYc` result is used.
  Benefits are read by array position, never by their localized display text.

Each account costs one page GET and one POST. An account with the credit at `authuser=1` refreshes with two of each,
and a profile is never read past eight accounts. A transient page GET failure is retried once.

The menu card shows:

- **Cloud credits**: the remaining part of the current monthly grant as a used-percentage bar with
  `$87.50 of $100.00 left · Expires 2027-11-07`. The grant expires instead of resetting, so its expiry is detail text,
  shown as a numeric Gregorian date in the local time zone. Setup, status, and error messages follow the app language.
- **Monthly credits**: the remaining amount, which the menu bar **Balance** element also shows. Amounts keep the
  currency the response reports. A grant and remaining balance with different currencies fail parsing rather than mixing amounts.
- **Billing**: the billing account ID the credit is applied to, and the date the grant was issued.

Other states:

- A credit that is not applied to a billing account yet shows **Status: Not applied** with a pointer to
  me.developers.google.com/benefits, where its **Apply** button links it to a billing account. This is not an error.
- When no signed-in account has the credit, the error points to the Google Developer Program benefits page to check eligibility.
- HTTP 429 reports a rate limit and HTTP 5xx reports the service as unavailable, keeping the session.

The signed-in email and the `Browser session` login label are the only identity fields.

CLI: `codexbar usage --provider google-developer --source web --json`. On Linux use a manual cookie header in the
config, since automatic browser import is macOS-only.
