#!/usr/bin/env python3
"""
mimo-usage — local token usage tracker for cc-mimo

Scans ~/.claude-envs/mimo/.claude/projects/**/*.jsonl session files,
sums input/output/cache tokens per time window (today/week/all),
writes to ~/.codexbar/mimo-local-usage.json, and prints a human-readable
summary by default.

Usage:
  mimo-usage              # show summary (also refreshes cache)
  mimo-usage --update     # refresh cache only, no output (for LaunchAgent/wrapper)
  mimo-usage --json       # JSON output
  mimo-usage --short      # 1-line status (for status line / widget)
"""
import json
import os
import sys
from pathlib import Path
from datetime import datetime, timedelta, timezone

MIMO_HOME = Path(os.environ.get("MIMO_CLAUDE_HOME", Path.home() / ".claude-envs" / "mimo")).expanduser()
PROJECTS_DIR = MIMO_HOME / ".claude" / "projects"
CACHE_PATH = Path(
    os.environ.get("MIMO_LOCAL_USAGE_PATH", Path.home() / ".codexbar" / "mimo-local-usage.json")
).expanduser()


def parse_session_usage(jsonl_path: Path):
    """Yield (identity, timestamp_iso, usage_dict) for each assistant message with usage."""
    try:
        with jsonl_path.open() as f:
            for line in f:
                try:
                    d = json.loads(line)
                    ts = d.get("timestamp")
                    msg = d.get("message")
                    if not isinstance(msg, dict):
                        continue
                    usage = msg.get("usage")
                    if not isinstance(usage, dict):
                        continue
                    if not ts:
                        continue
                    metadata = d.get("metadata")
                    message_metadata = msg.get("metadata")
                    session_id = d.get("sessionId") or d.get("session_id")
                    if not session_id and isinstance(metadata, dict):
                        session_id = metadata.get("sessionId")
                    if not session_id and isinstance(message_metadata, dict):
                        session_id = message_metadata.get("sessionId")
                    message_id = msg.get("id")
                    request_id = d.get("requestId") or d.get("request_id")
                    identity = None
                    if all(isinstance(value, str) and value for value in (message_id, request_id)):
                        identity = ("request", message_id, request_id)
                    elif (
                        request_id is None
                        and isinstance(session_id, str)
                        and session_id
                        and isinstance(message_id, str)
                        and message_id
                    ):
                        identity = ("legacy", session_id, message_id)
                    yield identity, ts, usage
                except (json.JSONDecodeError, ValueError):
                    continue
    except (OSError, IOError):
        return


def aggregate_usage():
    """Scan all mimo session jsonls and return windowed token sums."""
    now = datetime.now(timezone.utc)
    today_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    # Week starts on Monday 00:00 UTC
    week_start = today_start - timedelta(days=today_start.weekday())

    windows = {
        "today": {"input": 0, "output": 0, "cache_read": 0, "cache_create": 0, "messages": 0},
        "week": {"input": 0, "output": 0, "cache_read": 0, "cache_create": 0, "messages": 0},
        "all_time": {"input": 0, "output": 0, "cache_read": 0, "cache_create": 0, "messages": 0},
    }
    sessions_scanned = 0
    last_activity = None
    keyed_rows = {}
    unkeyed_rows = []

    if not PROJECTS_DIR.exists():
        return windows, sessions_scanned, last_activity

    for jsonl in PROJECTS_DIR.rglob("*.jsonl"):
        sessions_scanned += 1
        for identity, ts_str, usage in parse_session_usage(jsonl):
            try:
                # Parse ISO timestamp (may end with Z)
                ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
                if ts.tzinfo is None:
                    ts = ts.replace(tzinfo=timezone.utc)
            except (ValueError, TypeError):
                continue

            row = (ts, usage)
            if identity is None:
                unkeyed_rows.append(row)
            else:
                previous = keyed_rows.get(identity)
                if previous is None or ts >= previous[0]:
                    keyed_rows[identity] = row

    for ts, usage in [*keyed_rows.values(), *unkeyed_rows]:
        input_t = int(usage.get("input_tokens", 0) or 0)
        output_t = int(usage.get("output_tokens", 0) or 0)
        cache_read_t = int(usage.get("cache_read_input_tokens", 0) or 0)
        cache_create_t = int(usage.get("cache_creation_input_tokens", 0) or 0)

        if last_activity is None or ts > last_activity:
            last_activity = ts

        # all_time
        w = windows["all_time"]
        w["input"] += input_t
        w["output"] += output_t
        w["cache_read"] += cache_read_t
        w["cache_create"] += cache_create_t
        w["messages"] += 1

        if ts >= week_start:
            w = windows["week"]
            w["input"] += input_t
            w["output"] += output_t
            w["cache_read"] += cache_read_t
            w["cache_create"] += cache_create_t
            w["messages"] += 1

        if ts >= today_start:
            w = windows["today"]
            w["input"] += input_t
            w["output"] += output_t
            w["cache_read"] += cache_read_t
            w["cache_create"] += cache_create_t
            w["messages"] += 1

    return windows, sessions_scanned, last_activity


def write_cache(windows, sessions_scanned, last_activity):
    CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "updated_at": datetime.now(timezone.utc).isoformat(),
        "last_activity": last_activity.isoformat() if last_activity else None,
        "sessions_scanned": sessions_scanned,
        "windows": windows,
        "source": "local-jsonl-scan",
        "note": "Local token accounting from cc-mimo session jsonl. Not a quota; mimo platform.xiaomimimo.com SSO cookie required for real quota.",
    }
    tmp = CACHE_PATH.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(payload, indent=2))
    tmp.replace(CACHE_PATH)
    return payload


def fmt_tokens(n: int) -> str:
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.1f}k"
    return str(n)


def short_status(payload):
    """1-line status line."""
    w = payload["windows"]["week"]
    total = w["input"] + w["output"] + w["cache_read"] + w["cache_create"]
    return f"mimo: {fmt_tokens(total)} tok this week ({w['messages']} msg)"


def human_summary(payload):
    """Multi-line human-readable summary."""
    last = payload.get("last_activity")
    if last:
        try:
            last_dt = datetime.fromisoformat(last)
            ago = datetime.now(timezone.utc) - last_dt
            if ago.total_seconds() < 60:
                ago_str = "just now"
            elif ago.total_seconds() < 3600:
                ago_str = f"{int(ago.total_seconds() / 60)}m ago"
            elif ago.total_seconds() < 86400:
                ago_str = f"{int(ago.total_seconds() / 3600)}h ago"
            else:
                ago_str = f"{ago.days}d ago"
        except (ValueError, TypeError):
            ago_str = last
    else:
        ago_str = "never"

    lines = [
        "== MiMo (local tracker) ==",
        f"Sessions scanned: {payload['sessions_scanned']}",
        f"Last activity: {ago_str}",
        "",
    ]
    for window_name, label in [("today", "Today"), ("week", "This week"), ("all_time", "All time")]:
        w = payload["windows"][window_name]
        in_t = fmt_tokens(w["input"])
        out_t = fmt_tokens(w["output"])
        cr_t = fmt_tokens(w["cache_read"])
        cc_t = fmt_tokens(w["cache_create"])
        total = w["input"] + w["output"] + w["cache_read"] + w["cache_create"]
        lines.append(f"{label:>10}: {fmt_tokens(total):>8} total | in={in_t} out={out_t} cache_r={cr_t} cache_c={cc_t} | msg={w['messages']}")
    lines.append("")
    lines.append("Note: this is local accounting from cc-mimo session jsonl.")
    lines.append("Real platform quota requires Chrome cookie (cookieSource=manual).")
    return "\n".join(lines)


def main():
    args = sys.argv[1:]
    quiet = "--update" in args
    json_out = "--json" in args
    short = "--short" in args

    windows, sessions_scanned, last_activity = aggregate_usage()
    payload = write_cache(windows, sessions_scanned, last_activity)

    if quiet:
        return 0
    if json_out:
        print(json.dumps(payload, indent=2))
        return 0
    if short:
        print(short_status(payload))
        return 0

    print(human_summary(payload))
    return 0


if __name__ == "__main__":
    sys.exit(main())
