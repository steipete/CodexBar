#!/usr/bin/env python3
"""Exercise glibc heap relief through the built serve command and synthetic cost logs."""
import datetime
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request


def check_memory(binary, root):
    home = root / "home"
    sessions = home / ".codex" / "sessions"
    sessions.mkdir(parents=True)
    config = root / "config.json"
    config.write_text(json.dumps({"version": 1, "providers": [
        {"id": "codex", "enabled": True, "source": "cli"}]}))
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    pricing = home / ".cache" / "CodexBar" / "model-pricing"
    pricing.mkdir(parents=True)
    (pricing / "models-dev-v1.json").write_text(json.dumps({
        "version": 1, "fetchedAt": stamp, "catalog": {"providers": {"openai": {
            "id": "openai", "models": {"gpt-5.4": {
                "id": "gpt-5.4", "cost": {"input": 2.5, "output": 15}}}}}}}))
    for number in range(48):
        with (sessions / f"rollout-{number}.jsonl").open("w") as handle:
            handle.write(json.dumps({"type": "turn_context", "timestamp": stamp,
                                     "payload": {"model": "gpt-5.4"}}) + "\n")
            for turn in range(3000):
                handle.write(json.dumps({"type": "event_msg", "timestamp": stamp, "payload": {
                    "type": "token_count", "info": {"model": "gpt-5.4", "total_token_usage": {
                        "input_tokens": (turn + 1) * 100, "cached_input_tokens": 0,
                        "output_tokens": (turn + 1) * 10}}}}) + "\n")
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    environment = {"PATH": "/usr/bin:/bin", "HOME": str(home),
                   "CODEX_HOME": str(home / ".codex"), "CODEXBAR_CONFIG": str(config),
                   "XDG_CACHE_HOME": str(home / ".cache")}
    with (root / "server.log").open("w") as log:
        process = subprocess.Popen([str(binary), "serve", "--port", str(port),
                                    "--refresh-interval", "0", "--request-timeout", "0"],
                                   env=environment, stdout=log, stderr=log)
        def rss():
            for line in Path(f"/proc/{process.pid}/status").read_text().splitlines():
                if line.startswith("VmRSS:"):
                    return int(line.split()[1])
            raise AssertionError("server RSS is unavailable")

        def get(path):
            with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=120) as response:
                assert response.status == 200
                return json.load(response)

        try:
            ready_deadline = time.monotonic() + 30
            while True:
                try:
                    assert get("/health")["status"] == "ok"
                    break
                except OSError:
                    if process.poll() is not None or time.monotonic() >= ready_deadline:
                        raise AssertionError("fixture server did not become ready")
                    time.sleep(0.1)
            initial = rss()
            peaks = []
            for _ in range(3):
                rows = get("/cost?provider=codex")
                assert len(rows) == 1 and rows[0]["provider"] == "codex"
                assert not rows[0].get("error") and rows[0].get("daily")
                peaks.append(rss())
            peak = max(peaks)
            # This is a resident-memory assertion, not a refresh-latency assertion. Allow two
            # maintenance periods plus scheduling slack; never require an exact firing time.
            target = initial + max(16 * 1024, (peak - initial) * 0.75)
            deadline = time.monotonic() + 75
            idle = rss()
            while idle > target and time.monotonic() < deadline:
                time.sleep(1)
                assert get("/health")["status"] == "ok"
                idle = min(idle, rss())
            measurements = {"initial_kib": initial, "refresh_kib": peaks,
                            "idle_kib": idle, "target_kib": target}
            print(json.dumps(measurements), flush=True)
            assert idle <= target, "serve retained its transient refresh heap"
            print("heap-relief-ok", flush=True)
        finally:
            process.terminate()
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="codexbar-serve-memory-") as directory:
        check_memory(Path(sys.argv[1]).resolve(), Path(directory))
