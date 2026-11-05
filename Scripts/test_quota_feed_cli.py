#!/usr/bin/env python3
"""Exercise the shipped CLI with synthetic files, never live provider accounts.

Usage: python3 Scripts/test_quota_feed_cli.py NEW_CLI STABLE_CLI
The stable binary must be from the latest verified official release.
"""
import datetime
import hashlib
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request


def main():
    cli, stable = [str(Path(arg).resolve()) for arg in sys.argv[1:]]
    with tempfile.TemporaryDirectory(prefix="quota-feed-proof-") as directory:
        root = Path(directory)
        config = root / "config.json"
        feed = root / "quota.json"
        env = {
            "PATH": "/usr/bin:/bin",
            "CFFIXED_USER_HOME": directory,
            "XDG_CONFIG_HOME": directory,
            "CODEXBAR_CONFIG": str(config),
            "CODEXBAR_DISABLE_KEYCHAIN_ACCESS": "1",
            "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1",
            "CODEXBAR_TEST_CODEX_FILE_ISOLATION": "1",
            "CODEXBAR_TEST_SESSION_FILE_ISOLATION": "1",
        }

        def run(binary, *args, code=0):
            result = subprocess.run(
                [binary, *args], env=env, capture_output=True, text=True, timeout=30
            )
            assert result.returncode == code, (args, result.returncode)
            assert not result.stderr, args
            return result.stdout

        def read_config(binary):
            assert json.loads(run(binary, "config", "validate", "--json")) == []
            return json.loads(run(binary, "config", "dump"))

        print("Stable:", run(stable, "--version").strip())
        config.write_text(json.dumps({
            "version": 1,
            "providers": [
                {"id": "codex", "enabled": False, "source": "cli"},
                {"id": "claude", "enabled": False, "source": "auto"},
            ],
        }))
        # Persist through the actual stable writer before upgrading.
        run(stable, "config", "enable", "--provider", "codex")
        baseline = read_config(stable)
        assert baseline["providers"][0]["enabled"] is True
        original = config.read_bytes()
        upgraded = read_config(cli)
        assert config.read_bytes() == original

        def without_feed(value):
            return {**value, "providers": [
                p for p in value["providers"] if p["id"] != "quotafeed"
            ]}

        assert without_feed(upgraded) == baseline
        assert next(p for p in upgraded["providers"] if p["id"] == "quotafeed")["enabled"] is False
        # Exercise the new writer, then read it back with both binaries.
        run(cli, "config", "disable", "--provider", "codex")
        run(cli, "config", "enable", "--provider", "codex")
        assert without_feed(read_config(cli)) == baseline
        assert without_feed(read_config(stable)) == baseline
        print("Upgrade: stable-written config loads unchanged; all existing fields and provider order preserved")
        print("Upgrade: new writer round trip preserves settings; stable binary can still read them")

        # Disable every real provider before invoking usage or the local server.
        for provider in upgraded["providers"]:
            provider["enabled"] = False
            if provider["id"] == "quotafeed":
                provider.update(enabled=True, quotaFeedPath=str(feed))
        config.write_text(json.dumps(upgraded))
        for label, age, used in [("current", 0, 25), ("stale", 901, 25), ("recovered", 0, 30)]:
            observed = (datetime.datetime.now(datetime.timezone.utc)
                        - datetime.timedelta(seconds=age)).strftime("%Y-%m-%dT%H:%M:%SZ")
            replacement = root / "next.json"
            replacement.write_text(json.dumps({
                "version": 1, "observedAt": observed,
                "used": used, "limit": 100, "currency": "USD",
            }))
            replacement.replace(feed)
            code = 1 if age else 0
            payload = json.loads(run(cli, "usage", "--provider", "quotafeed", "--source", "cli", "--json", code=code))
            assert len(payload) == 1 and payload[0]["provider"] == "quotafeed"
            item = payload[0]
            if age:
                assert "usage" not in item and "stale" in item["error"]["message"]
            else:
                assert item["source"] == "local file"
                assert item["usage"]["primary"]["usedPercent"] == used
                assert item["usage"]["updatedAt"] == observed
                rows = item["usage"]["details"][0]["rows"]
                assert next(row["value"] for row in rows if row["label"] == "Remaining") == f"{100-used:.2f} USD"
            assert directory not in json.dumps(payload)
            print(f"{label}: exit={code} " + json.dumps(payload, sort_keys=True))

        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        server = subprocess.Popen(
            [cli, "serve", "--host", "127.0.0.1", "--port", str(port)],
            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        try:
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            url = f"http://127.0.0.1:{port}"
            for attempt in range(50):
                try:
                    response = opener.open(url + "/icons/ProviderIcon-quotafeed.svg", timeout=2)
                    break
                except urllib.error.URLError:
                    assert server.poll() is None, "serve exited before ready"
                    time.sleep(0.1)
            else:
                raise AssertionError("serve did not become ready")
            with response:
                actual = response.read()
                assert response.status == 200
                assert response.headers.get_content_type() == "image/svg+xml"
            resource = Path(__file__).resolve().parent.parent / "Sources/CodexBar/Resources/ProviderIcon-quotafeed.svg"
            assert actual == resource.read_bytes()
            with opener.open(url + "/", timeout=2) as response:
                assert b'"quotafeed":"/icons/ProviderIcon-quotafeed.svg"' in response.read()
            print("Icon: HTTP 200 image/svg+xml; exact resource SHA256=" + hashlib.sha256(actual).hexdigest())
            print("Dashboard: Quota Feed icon mapping present")
        finally:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait(timeout=5)
        print("PASS: CLI ingestion, stale recovery, stable upgrade, persisted settings, and standalone icon")


if __name__ == "__main__":
    main()
