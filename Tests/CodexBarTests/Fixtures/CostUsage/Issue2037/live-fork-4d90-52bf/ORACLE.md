# Hand oracle: live fork 4d90→52bf (sanitized)

Derived from a local Sol/Terra Ultra-adjacent fork (`019f4d90` → `019f52bf`).
Message bodies, paths, and real session IDs are stripped/aliased. Parent file is
**truncated to the copied prefix** (N=180) so this is a clean resolved-fork golden;
the live parent continued after the fork and is not fully represented here.

| Stream | Token rows | Sum of `last.total_tokens` |
|---|---:|---:|
| Parent (prefix only) | 180 | 25,129,283 |
| Child all | 196 | 26,938,802 |
| Child unique suffix | 16 | 1,809,519 |

```text
naive parent+child (last.total_tokens) = 52,068,085
deduped parent-owns-prefix (last.total_tokens) = 26,938,802
N = 180
```

## Scanner units (integration)

CostUsageScanner follows **`total_token_usage` deltas**, not `sum(last)`.
Parent ordinal **120** has `last` scanner units 225,513 with **Δtotal = 0**, so
`sum(last)` overcounts the parent stream vs the scanner.

| Metric | Scanner units (`input+cached+output`) |
|---|---:|
| Parent final totals | 48,730,248 |
| Child unique (Δ totals) | 3,455,599 |
| Deduped family (`#1164`) | 52,185,847 |
| Naive both finals | 100,916,095 |

With parent present, `#1164` should match `deduped` scanner units
(`Issue2037ScannerIntegrationTests`). Because the parent is truncated to the
copied prefix, that family total equals the child's final cumulative totals.

Not an Ultra interleaved golden. Not a claim that #2037 is closed.
