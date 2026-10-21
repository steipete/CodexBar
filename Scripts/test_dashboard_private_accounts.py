#!/usr/bin/env python3
"""Exercise expanded dashboard HTTP output using synthetic files and a fake Codex RPC process."""

import base64
import json
import pathlib
import socket
import subprocess
import tempfile
import urllib.error
import urllib.request


def verify(binary, root):
    def jwt(value):
        return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")

    homes = [root / "profile-a", root / "profile-b"]
    for home in homes:
        home.mkdir()
        identity = {"email": home.name + "@example.test", "chatgpt_plan_type": "plus"}
        (home / "auth.json").write_text(json.dumps({"tokens": {
            "accessToken": "synthetic-access", "refreshToken": "synthetic-refresh",
            "idToken": jwt({"alg": "none"}) + "." + jwt(identity) + ".synthetic",
        }}))
    app = root / "Library/Application Support/CodexBar"
    app.mkdir(parents=True)
    managed_id = "9e122a52-b3db-4a7e-a7a7-c3b8fc9d01e9"
    (app / "managed-codex-accounts.json").write_text(json.dumps({"version": 3, "accounts": [{
        "id": managed_id, "email": "profile-a@example.test", "workspaceLabel": "Private Team",
        "managedHomePath": str(homes[0]), "createdAt": 1000, "updatedAt": 1000,
    }]}))
    config = root / "config.json"
    config.write_text(json.dumps({"version": 1, "providers": [{
        "id": "codex", "enabled": True, "source": "cli",
        "codexProfileHomePaths": [str(homes[1])],
        "codexActiveSource": {"kind": "profileHome", "homePath": str(homes[1])},
    }]}))
    stub = root / "codex"
    stub.write_text('''#!/usr/bin/python3 -S
import json, os, pathlib, sys
if "--version" in sys.argv:
    print("codex-cli 1.0.0")
    sys.exit(0)
assert "app-server" in sys.argv
home = pathlib.Path(os.environ["CODEX_HOME"])
for line in sys.stdin:
    request = json.loads(line)
    if "id" not in request:
        continue
    result = {}
    if request.get("method") == "account/rateLimits/read":
        result = {"rateLimits": {"planType": "plus", "primary": {
            "usedPercent": 20 if home.name == "profile-a" else 65, "windowDurationMins": 300}}}
    elif request.get("method") == "account/read":
        result = {"account": {"type": "chatgpt", "email": home.name + "@example.test",
                              "planType": "plus"}, "requiresOpenaiAuth": False}
    print(json.dumps({"id": request["id"], "result": result}), flush=True)
''')
    stub.chmod(0o755)
    environment = {
        "HOME": str(root), "CFFIXED_USER_HOME": str(root), "CODEX_HOME": str(root / "empty"),
        "CODEXBAR_CONFIG": str(config), "CODEX_CLI_PATH": str(stub), "PATH": "/usr/bin:/bin",
        "SHELL": "/bin/sh", "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1",
        "CODEXBAR_DISABLE_KEYCHAIN_ACCESS": "1", "CODEXBAR_TEST_SESSION_FILE_ISOLATION": "1",
        "CODEXBAR_TEST_CODEX_FILE_ISOLATION": "1",
        "CODEXBAR_TEST_CODEX_FILE_FIXTURES": json.dumps({"grants": [
            {"url": root.as_uri(), "resolvedURL": root.as_uri(), "isRoot": True},
        ]}),
    }
    ids = None
    for mode in ["ordinary", "private", "redacted", "full"]:
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        options = [] if mode == "ordinary" else ["--all-accounts"]
        if mode in ["full", "redacted"]:
            options += ["--identity", mode]
        server = subprocess.Popen(
            [binary, "serve", "--port", str(port), "--dashboard-token", "synthetic-test-token",
             "--request-timeout", "30", *options],
            env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        )
        try:
            assert b"listening" in server.stderr.readline(), "server not ready (diagnostics withheld)"
            url = f"http://127.0.0.1:{port}/dashboard/v1/snapshot"
            try:
                urllib.request.urlopen(url, timeout=45)
                raise AssertionError("unauthenticated snapshot accepted")
            except urllib.error.HTTPError as error:
                assert error.code == 401 and error.headers["Cache-Control"] == "no-store"
            request = urllib.request.Request(url, headers={"Authorization": "Bearer synthetic-test-token"})
            with urllib.request.urlopen(request, timeout=45) as response:
                assert response.status == 200 and response.headers["Cache-Control"] == "no-store"
                body = response.read().decode()
                row = json.loads(body)["providers"][0]
            accounts = row["accounts"]
            assert accounts[0]["id"] == "codex-managed:" + managed_id
            if mode == "ordinary":
                assert len(accounts) == 1 and accounts[0]["windows"] == []
                assert not accounts[0]["active"]
                print("PASS ordinary HTTP: saved managed snapshot retained")
                continue
            assert len(accounts) == 2 and [account["active"] for account in accounts] == [False, True]
            assert [account["windows"][0]["usedPercent"] for account in accounts] == [20, 65]
            assert row["windows"][0]["usedPercent"] == 65 and row["error"] is None
            observed = [account["id"] for account in accounts]
            assert ids is None or observed == ids
            ids = observed
            if mode != "full":
                assert [account["label"] for account in accounts] == ["Account 1", "Account 2"]
                assert not any(value in body for value in ["Private Team", "profile-a@", "profile-b@", str(root)])
            if mode == "private":
                assert row["identity"] is None and all(account["identity"] is None for account in accounts)
            else:
                email = "profile-b@example.test" if mode == "full" else "redacted@example.test"
                assert row["identity"]["accountEmail"] == email
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/usage", timeout=45) as response:
                assert len(json.load(response)) == 2
            print(f"PASS {mode} HTTP: 2 live accounts, selected usage, stable IDs, privacy, auth, no-store, raw usage")
        finally:
            server.terminate()
            try:
                server.wait(timeout=30)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()


def main():
    binaries = list(pathlib.Path(".build").glob("*/debug/CodexBarCLI"))
    assert len(binaries) == 1, "Expected one local debug CodexBarCLI"
    with tempfile.TemporaryDirectory(prefix="private-dashboard-fixture-") as directory:
        verify(str(binaries[0].resolve()), pathlib.Path(directory))


if __name__ == "__main__":
    main()
