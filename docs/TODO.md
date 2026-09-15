---
summary: "Compatibility constraints to check before retiring legacy Claude quota fields."
read_when:
  - Grooming backlog or planning maintenance
  - Reviewing legacy Claude quota compatibility
---

## Claude quota compatibility

The former December 2025 cleanup deadline did not establish that Claude's Opus quota fallback is unused.
The CLI parser still accepts `Current week (Opus)`, and the OAuth mapper still falls back to `sevenDayOpus`.
Public snapshots also retain the legacy `opus` fields used to project the tertiary quota window.

Keep those paths while these source formats and public fields are supported. Any retirement must name the
replacement formats and migration boundary, preserve remaining model-scoped quota windows, and document the
compatibility change. A date alone is not evidence that the fallback is dead.
