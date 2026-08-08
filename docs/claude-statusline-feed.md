# Claude statusLine usage feed (opt-in)

Claude Code passes a JSON object on stdin to whatever `statusLine` command you configure, and for
Claude.ai-subscriber sessions that object carries a `rate_limits` block:

```json
{
  "rate_limits": {
    "five_hour": { "used_percentage": 42.7, "resets_at": 1786099200 },
    "seven_day": { "used_percentage": 63.1, "resets_at": 1786608000 }
  }
}
```

Those numbers ride along with responses the session already made, so reading them costs nothing against the
OAuth usage endpoint's budget. This feed lets CodexBar show them between polls.

## What it is and is not

- **Off by default.** Nothing reads or writes anything until you turn it on.
- **Additive.** It joins the Auto order behind OAuth and ahead of the CLI probe. A successful OAuth read still
  wins; this fills the gap while the polled sources are cooling down.
- **Not selectable as a source.** The feed is silent whenever you are not running Claude Code, so pinning it
  would strand the card. It only ever participates inside Auto.
- **Fail soft.** A payload CodexBar cannot make sense of reads as "no live data", never as an error. Claude Code
  owns this schema and may change it; the status line is your configuration, not CodexBar's.

## Wiring it up

CodexBar reads drop files from `~/Library/Application Support/CodexBar/claude-statusline/`. Have your
`statusLine` command write one. The envelope:

```json
{
  "schema": 1,
  "capturedAt": 1786099200,
  "configDir": "/Users/you/.claude",
  "payload": { "...": "the JSON Claude Code passed you on stdin" }
}
```

A minimal shim, which you can call from your own status line:

```sh
#!/bin/sh
# Forward Claude Code's rate_limits to CodexBar, then render your status line as usual.
payload=$(cat)
dir="$HOME/Library/Application Support/CodexBar/claude-statusline"
case "$payload" in
  *'"rate_limits"'*)
    mkdir -p "$dir"
    id=$(printf '%s' "${CLAUDE_CONFIG_DIR:-default}" | shasum | cut -c1-16)
    tmp="$dir/.$id.tmp"
    umask 077
    printf '{"schema":1,"capturedAt":%s,"configDir":"%s","payload":%s}' \
      "$(date +%s)" "${CLAUDE_CONFIG_DIR:-}" "$payload" > "$tmp" && mv "$tmp" "$dir/$id.json"
    ;;
esac
# ... your own status line output here ...
```

Notes:

- `capturedAt` is required. An observation without a usable capture time is discarded — it cannot be aged, and
  treating it as current would let a file that has sat on disk for hours outrank a live poll.
- Write atomically (`mv` over a temp file). CodexBar may read while you write.
- `configDir` must be the session's `CLAUDE_CONFIG_DIR`, or empty for the default profile. CodexBar drops
  observations whose profile does not match the account it is showing, so a wrong value means the feed is
  ignored rather than misattributed.
- The status line runs several times per second while a response streams. Gate on `rate_limits` being present,
  and throttle if you care about the write volume — CodexBar only ever uses the newest file.
- Observations older than 15 minutes are ignored, so a dead session cannot outrank a fresh poll. A
  timestamp more than 5 minutes in the future is rejected too — modest clock skew is tolerated, but an
  arbitrarily future one would never expire.

## What the card shows

While the feed is serving the numbers, the Claude card notes that they came from your statusLine
configuration. Identity, plan, model-scoped weekly, Daily Routines and extra usage are not part of this
payload and continue to come from the polled sources.
