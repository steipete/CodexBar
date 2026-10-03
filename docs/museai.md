---
summary: "Muse provider: muse.ai Free, Power, and Maximum weekly usage from browser session cookies."
read_when:
  - Configuring muse.ai usage tracking
  - Debugging muse.ai session cookies or server-action discovery
---

# Muse (muse.ai) Provider

[Muse](https://muse.ai) is Meta's personal agent. Its Free, Power, and Maximum plans share one weekly token allowance.
This is separate from [Muse Code](muse.md), which reads the `muse` CLI login.

Sign in at `muse.ai` in a supported browser for **Automatic** import, or choose **Manual** and paste a Cookie header.
Automatic import follows SweetCookieKit's default browser order, including Aside, Opera, and Opera Neon as of 0.5.5.
The Cookie source description and missing-session message list the supported browsers directly from that catalog.
Existing profile and Keychain access checks still apply. **Off** disables cookie access. For browsers outside the
catalog, choose **Manual** and paste a Cookie header from a signed-in `muse.ai` request.
On Linux, use a manual Cookie header; no browser integration or Muse Code CLI login is needed. CodexBar shows the weekly
percentage, reset time, plan, tokens left (paid plans), renewal date, and any additional (top-up) tokens.

muse.ai has no usage API. `museai.js` posts the settings dialog's Next.js server action (`fetchSubscriptionAction`) with
`Sec-Fetch-*` headers, since muse.ai rejects other server-action requests with 403. The action ID changes on each deploy,
so the plugin stores the ID only after a successful subscription response. On `404 Server action not found.` it loads the signed-in page's chunks, finds
the lazy module that preloads settings, and reads the new ID from that module's chunk. A redirect to `auth.muse.ai` or a
403 means that session expired, and the plugin tries the next browser session before reporting it.

Discovery fetches at most 96 page chunks and 32 settings chunks, in batches of at most eight, within the host's
fetch deadline. Static chunks receive no session cookies. After a stale ID, the plugin discovers and retries once;
if the replacement action also fails, it clears the stale ID and reports that the subscription action changed.
Website changes beyond the supported loader format produce a clear parse error rather than an unbounded scan.

The subscription response reports percentages, not raw weekly token totals. Paid-plan token text is preserved
from the website. Additional token balances are separate from weekly usage; if their label is absent, their
micro-dollar amount is converted to USD rather than displayed as a token count.
