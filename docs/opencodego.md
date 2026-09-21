---
summary: "OpenCode Go provider entry point: subscription usage, source selection, and local SQLite cost history."
read_when:
  - Configuring OpenCode Go separately from OpenCode
  - Finding OpenCode Go usage and local-history documentation
---

# OpenCode Go

OpenCode Go is registered separately from OpenCode as `opencodego`. It supports `auto`, `api`, and `web` sources,
with five-hour, weekly, and monthly quota windows when reported by the selected source. Local cost history reads
OpenCode Go assistant records from `~/.local/share/opencode/opencode.db`.

The shared [OpenCode guide](opencode.md) documents authentication, scoped source selection, usage mapping, and the
boundary between device-local estimates and account quota. Keep those details there so the two guides do not drift.

```bash
codexbar usage --provider opencodego --format json --pretty
```
