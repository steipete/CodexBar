# Hand oracle: missing-parent siblings

Two children reference `missing-parent-session`, which is **not** present in the
fixture. Both carry the same 135-event normalized usage prefix; each then has a
distinct unique suffix.

| Stream | Token rows | Scanner units `sum(last.input+cached+output)` |
|---|---:|---:|
| Shared prefix (once) | 135 | 25,547,233 |
| Sibling A unique | 23 | 3,311,641 |
| Sibling B unique | 3 | 3,396 |

```text
naive = sibling-a all + sibling-b all = 54,409,503
ideal prefix-once dedupe = 28,862,270
unresolved-fork first-event skip on owner (#1164) = 25,671
scanner deduped oracle = 28,836,599
```

Desired billable prefix owner: **sibling-a** (deterministic: earliest fork
timestamp, then session id). This is a hand oracle for a future provenance
ledger, not authorization for token-only runtime suppression.

`#1164` alone cannot fix this: there is no parent file to inherit from, so each
child bills nearly the full prefix. Runtime cross-file dedupe intentionally
fails open because distinct sibling events can have equal token vectors. The
unresolved-fork path still skips the first totals row (pre-existing); the target
scanner oracle subtracts one owner skip from the ideal prefix-once total.

Not an Ultra interleaved golden. Not a claim that #2037 is closed.
