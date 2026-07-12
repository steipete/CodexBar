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

Billable prefix owner: **sibling-a** (deterministic: earliest fork timestamp, then
session id). Sibling-b prefix rows are billing-suppressed (state still advances).

`#1164` alone cannot fix this: there is no parent file to inherit from, so each
child billed nearly the full prefix before provisional suppressions. The
unresolved-fork path still skips the owner's first totals row (pre-existing);
the scanner oracle subtracts that skip from the ideal prefix-once total.

Not an Ultra interleaved golden. Not a claim that #2037 is closed.
