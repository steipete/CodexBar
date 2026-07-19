# Hand oracle: archived ordinary fork

This is a sanitized local Codex archived family.  IDs, timestamps, paths, and
the model label are synthetic aliases.  The JSONL contains only `session_meta`,
minimal `turn_context`, and `token_count` usage objects; it contains no message
content, tool output, cwd, credentials, or diffs.

The unit below is the stored `last_token_usage.total_tokens` field.  Do **not**
reconstruct it by adding `cached_input_tokens`: cached input is represented
inside the provider's reported total and is not additive here.

| Stream | Token rows | Sum of `last.total_tokens` |
|---|---:|---:|
| Parent | 135 | 13,432,621 |
| Child | 158 | 15,352,834 |

The longest contiguous normalized `(last_token_usage, total_token_usage)`
prefix is **N = 135**.  Every parent row is copied into the child's first 135
rows.  The remaining 23 child rows are unique:

```text
copied child prefix = 13,432,621
child unique suffix = 15,352,834 - 13,432,621 = 1,920,213

naive parent + child = 13,432,621 + 15,352,834 = 28,785,455
parent-owns-prefix = 13,432,621 + 1,920,213 = 15,352,834
overcount removed = 13,432,621
```

All 135 matched copied rows deliberately have different synthetic event
timestamps between parent and child.  Therefore timestamp equality is neither
required nor used by the prefix matcher.  Neither file has a decrease in its
stored `total_token_usage.total_tokens` sequence.

Fixture event timestamps use midday UTC on `2030-01-01` (parent) /
`2030-01-01` fork + `2030-01-02` unique child work so local timezones do not
map parent rows outside a Jan 1–2 report window.

**Scanner note:** with the parent file present in-window, current `#1164`
inherited-totals accounting already matches the parent-owns-prefix
`scannerUnits` oracle (`Issue2037ScannerIntegrationTests`). This golden locks
that regression. It does **not** cover missing-parent sibling families or
intra-file interleaved Ultra drops.

This is an ordinary cross-file fork golden, not an Ultra/interleaved golden. It
is P0 evidence and must not be used to claim that #2037 is fixed or closed.
