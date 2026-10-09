# Synthetic PTY redraw fixtures

`usage-pty-differential-redraw.ansi` preserves the diff-frame layout from @fanwenlin's #3822 fixture. Unrelated startup output is removed; workspace and tool names are synthetic. Quotas and reset labels are fixed test data. The crucial redraw writes `us`, jumps past the previous frame's `e` in `does`, then writes `d`: stripping CSI sequences leaves `51%usd` instead of `51% used`.

`status-pty-differential-redraw.ansi` paints an old synthetic identity, then replaces it with `fixture@example.com`, `Example Org`, and `Claude Max Account`, using cursor jumps for spaces and erase-line for stale suffixes. No real CLI or account is used.

`usage-pty-2.1.294-tall-panel.ansi` is a real Claude Code 2.1.294 `/usage` capture from a 200×160 PTY, starting where the probe clears its buffer before typing the command. The panel opens with session cost stats and a plugin footprint and ends with a usage-insights list, about 100 rows for this account; with Claude's default inline renderer in the former 50-row PTY, "Current session" scrolled off the replayed screen (seen on 2.1.270 through 2.1.294; the opt-in fullscreen renderer keeps it on screen). The owner's skill description in the command palette is blanked to `x`s and skill, plugin, MCP server and time zone names are replaced with synthetic ones of the same length, so every cursor position still lines up.
