---
summary: "Perplexity provider: browser cookie setup, credits API, recurring/bonus/purchased credit display."
read_when:
  - Configuring Perplexity usage
  - Debugging Perplexity browser cookie import or manual session tokens
  - Adjusting Perplexity credit display
---

# Perplexity Provider

CodexBar reads Perplexity account credit data with a Perplexity web session cookie. It does not use a Perplexity API
key and does not support token-cost history.

## Setup

1. Open **Settings -> Providers**.
2. Enable **Perplexity**.
3. Sign in to [perplexity.ai](https://www.perplexity.ai/) in a supported browser.
4. Leave Cookie source on **Automatic**, or switch to **Manual** and paste a full `Cookie:` header or a bare
   Perplexity session-token value.

Manual mode accepts these session cookie names:

- `__Secure-authjs.session-token`
- `authjs.session-token`
- `__Secure-next-auth.session-token`
- `next-auth.session-token`

You can also provide credentials through the environment:

```bash
export PERPLEXITY_SESSION_TOKEN="..."
export PERPLEXITY_COOKIE="__Secure-next-auth.session-token=..."
```

## Data Source

CodexBar requests:

- `GET https://www.perplexity.ai/rest/billing/credits?version=2.18&source=default`

The request sends the resolved Perplexity session cookie, `Origin: https://www.perplexity.ai`, and
`Referer: https://www.perplexity.ai/account/usage`.

Automatic mode tries any cached Perplexity cookie first, then imports browser cookies, then falls back to environment
variables. Browser-imported cookies are cached and invalid cached cookies are cleared after a rejected request.

## Display

- **Credits**: recurring account credits when Perplexity reports them.
- **Bonus credits**: promotional or bonus credits.
- **Purchased**: on-demand purchased credits.
- **Renewal**: recurring credits use the renewal timestamp when the API returns one.

Purchased credits do not reset, so the menu displays that balance without a reset prefix.

## CLI Usage

```bash
codexbar usage --provider perplexity --verbose
```

## Troubleshooting

### "Perplexity session token is missing"

Sign in to [perplexity.ai](https://www.perplexity.ai/) and refresh CodexBar, or paste a fresh cookie/session token in
manual mode.

### "Perplexity session token is invalid or expired"

Log out and back in to Perplexity. If manual mode is enabled, paste a new `Cookie:` header or session-token value.

### Credits do not appear

Open [Perplexity account usage](https://www.perplexity.ai/account/usage) in the same browser profile and confirm the
account has visible credit data.

## Related Files

- `Sources/CodexBarCore/Providers/Perplexity/PerplexityProviderDescriptor.swift`
- `Sources/CodexBarCore/Providers/Perplexity/PerplexityUsageFetcher.swift`
- `Sources/CodexBarCore/Providers/Perplexity/PerplexityUsageSnapshot.swift`
- `Sources/CodexBarCore/Providers/Perplexity/PerplexityCookieHeader.swift`
- `Sources/CodexBar/Providers/Perplexity/PerplexityProviderImplementation.swift`
