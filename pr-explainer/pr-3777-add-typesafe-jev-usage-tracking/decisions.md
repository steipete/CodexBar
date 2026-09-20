# Decisions

- Added Jev as a browser-cookie provider because TypeSafe's public Jev API documents per-request token usage, while account-level usage is exposed by the authenticated console endpoint used by the TypeSafe dashboard.
- Reused CodexBar's existing cookie cache, browser import order, manual-cookie setting, provider fetch strategy, and detail-row presentation instead of introducing a new credential mechanism.
- Aggregated the daily dashboard buckets into request, input-token, output-token, and total-token rows. The response does not expose a stable quota window or account credit limit, so the provider intentionally avoids inventing a percentage bar or balance.
- Kept the parser independent from live network calls so unit tests can validate aggregation without credentials or real provider probes.
