# Grok / OpenCodex producer-to-dashboard evidence

The captured ledger at `Tests/CodexBarTests/Fixtures/GrokOpenCodex/usage.jsonl` was written by the production OpenCodex server, request handlers, and durable usage logger at commit `146ed679c9633e5d68726217fcadc8e0b107339b` ([producer PR #3642](https://github.com/lidge-jun/opencodex/pull/3642)). Bun version: 1.4.0.

Two localhost HTTP requests went through that server. OAuth credentials and the xAI/Grok and identity-provider responses came from OpenCodex's isolated upstream fixtures. Unexpected external requests were rejected. This capture exercises real routing, OAuth replay, native Chat dispatch, logging, file import, cache persistence, and dashboard projection; it is not evidence of live vendor authentication or billing. All identity labels belong to artificial fixture accounts. No user credentials or conversation text appear in the captured ledger.

## Producer result

The unmodified production handlers persisted these physical attempts:

| Inbound request | Resolved adapter | Persisted credential source | Upstream sends | Reported tokens |
| --- | --- | --- | ---: | ---: |
| Responses, OAuth 401 then success | `openai-responses` | `grok-oauth` | 2 | 5 |
| Native Chat Completions, API key | `openai-chat` | `xai-api-key` | 1 | 5 |

The source stamp comes after resolved transport/adapter selection in Responses, and from `activeProvider` when native Chat builds or rebuilds its outbound request. OpenCodex's persistence normalizer retains only the two fixed source values on `xai` attempts. The captured bytes retain the full production ledger shape, including attempts, recovery kinds, and route-decision metadata.

Initial producer run: 2 tests passed, 23 assertions, zero failures. Captured ledger SHA-256:

```
ef6d8758b40910f6e5993d5b5a105a2ad2834c6c1bd0565ab87b61cf091c4978
```

## CodexBar import result

`GrokOpenCodexUsageTests` copies those exact bytes to an isolated `OPENCODEX_HOME/usage.jsonl`, supplies only an isolated cache directory, and calls the production dashboard disk loader. It supplies no injected entries or entry-loader closure. A second call constructs a new store and reads the persisted cache. A third import keeps only the exact producer-written API-key line.

Captured terminal output from the passing consumer test:

```
producer_capture_sha256=ef6d8758b40910f6e5993d5b5a105a2ad2834c6c1bd0565ab87b61cf091c4978
producer_log_rows=2 total_reported_tokens=10 grok_oauth_tokens=5
producer_import_dashboard_tokens=5 cache_reopen_bytes=0
producer_api_key_only_subscription_rows=0
```

The production dashboard model displays 5 tokens. The API-key attempt contributes none to the Grok row. Existing focused regressions separately verify estimated dollars, mixed recorded/estimated date filters, malformed and historic records, and cache upgrades.

## In-flight native scan cancellation

`CostUsageScanExecutorTests` runs the Grok scanner through the actual executor on an isolated serial queue. A barrier after 32 cancellation checks confirms chunk parsing has started; the test then cancels the awaiting Swift task and queues another scan. Cancellation returns `CancellationError`, the second scan runs, and parsing stops before the full 40,000-line corpus. The test checks a one-second release bound.

Observed result from the passing run:

```
grok_cancel_decoded_lines=4874/40000
grok_cancel_queue_release=0.001392625 seconds
```

This is a controlled executor/scanner measurement, not an app-wide latency guarantee. Both production async Grok entry points now pass the executor callback through discovery, JSONL reads, and per-turn aggregation. Cancelled partial parses remain uncacheable and cannot establish complete history.

## Reproduce

Use a clean OpenCodex checkout at the pinned commit with its locked dependencies installed. The capture helper refuses another commit or a dirty checkout. It copies the upstream fixture runner, adds ledger export before fixture teardown, and rejects unexpected upstream fetches; production OpenCodex source is unchanged.

```sh
python3 Scripts/capture_grok_opencodex_proof.py \
  --opencodex-root /path/to/pinned/opencodex \
  --output-dir /tmp/new-grok-producer-capture

CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS=1 \
CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS=0 \
CODEXBAR_TEST_CODEX_FILE_ISOLATION=1 \
swift test --filter 'GrokOpenCodexUsageTests|CostUsageScanExecutorTests'
```

A second capture using the committed helper independently passed with the same sources, send counts, and token totals. Its SHA-256 was `f43560d58af9805185607a7643f836af4fb0bda15102678a9742b0977785f8d4`. Timestamps, request IDs, route-decision IDs, durations, and anonymous fixture labels vary between captures, so reproduction hashes are expected to differ. The checked-in consumer fixture is deliberately pinned to the initial bytes.
