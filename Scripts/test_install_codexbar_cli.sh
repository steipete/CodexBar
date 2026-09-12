#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codexbar-cli-installer.XXXXXX")
trap 'rm -rf "$TEMP_DIR"' EXIT

# macOS only: AppleScript evaluates the command as text, never with privileges.
python3 - "$ROOT/bin/install-codexbar-cli.sh" "$TEMP_DIR" <<'PY'
import json
import os
import shlex
import subprocess
import sys
from pathlib import Path

assert sys.platform == "darwin", "The installer regression test requires macOS AppleScript."
assert os.geteuid() != 0, "Run installer regression tests as a non-root user."
source = Path(sys.argv[1]).read_text()
temp = Path(sys.argv[2]).resolve()
assert source.startswith("#!/bin/sh -p\n")
app_line = 'APP="/Applications/CodexBar.app"'
assert source.count(app_line) == 1
assert source.count("/usr/bin/osascript") == 1
assert 'HELPER="$APP/Contents/Helpers/CodexBarCLI"' in source

app = temp / "CodexBar's spaced \"quoted\" $literal `name`\napp.app"
helper = app / "Contents/Helpers/CodexBarCLI"
helper.parent.mkdir(parents=True)
helper.write_text("#!/bin/sh\nexit 0\n")
helper.chmod(0o755)
capture = temp / "capture.json"
stub = temp / "osascript-stub"
stub.write_text(f"#!{sys.executable}\n" + '''
import json
import os
import sys
from pathlib import Path

temp = Path(__file__).parent
(temp / "capture.json").write_text(json.dumps({
    "args": sys.argv[1:], "script": sys.stdin.read(), "environment": dict(os.environ),
}))
sys.exit(int((temp / "exit-code").read_text()))
''')
stub.chmod(0o755)
(temp / "exit-code").write_text("0")

# Redirect only the helper fixture and osascript. No production test overrides.
fixture = temp / "installer.sh"
fixture.write_text(source.replace(app_line, "APP=" + shlex.quote(str(app)))
                   .replace("/usr/bin/osascript", shlex.quote(str(stub))))
fixture.chmod(0o755)
environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(temp)}

hook = temp / "startup-hook"
hook.write_text("/bin/echo startup-hook-ran >&2\nexit 97\n")
startup_hooks = {"BASH_ENV": str(hook), "ENV": str(hook), "PATH": str(temp)}
function_returns = {name: 98 for name in (
    "bash", "env", "osascript", "mkdir", "ln", "dirname", "echo", "printf",
)}
# Each override models a distinct way to bypass validation or fail-fast behavior.
function_returns.update({"[": 1, "set": 0, "exit": 0})

def run_command(command, functions=(), inherited=None):
    if functions or inherited:
        # Let the system Bash choose its actual function-export format. Inject hooks
        # only after this exporter starts, so they reach the installer, not the test.
        exports = "".join(
            f"{name}() {{ /bin/echo inherited-function-ran:{name} >&2; "
            f"return {function_returns[name]}; }}\nexport -f {shlex.quote(name)}\n"
            for name in functions
        )
        launch = shlex.join(["/usr/bin/env"] + [
            f"{key}={value}" for key, value in (inherited or {}).items()
        ]) + ' "$@"'
        command = ["/bin/bash", "--noprofile", "--norc", "-c", exports + launch,
                   "installer-test", *command]
    return subprocess.run(command, env=environment, capture_output=True, text=True)

def run_installer(functions=(), inherited=None):
    return run_command([str(fixture)], functions, inherited)

# Prove these are genuinely inherited functions on this host, without invoking them.
imported = run_command(["/bin/sh", "-c", "type -t '[' set exit"], ("[", "set", "exit"))
assert imported.returncode == 0, imported.stderr
assert imported.stdout.splitlines() == ["function"] * 3
hook_probe = run_command(["/bin/bash", "--noprofile", "--norc", "-c", ":"], inherited=startup_hooks)
assert hook_probe.returncode == 97
assert hook_probe.stderr == "startup-hook-ran\n"

cases = [
    ("normal", (), {}),
    ("test function", ("[",), {}),
    ("set function", ("set",), {}),
    ("exit function", ("exit",), {}),
    ("all functions", tuple(function_returns), {}),
    ("startup hooks", (), startup_hooks),
    ("shell options", (), {"SHELLOPTS": "noexec"}),
    ("all contamination", tuple(function_returns), dict(startup_hooks, SHELLOPTS="noexec")),
]

baseline = run_installer()
assert baseline.returncode == 0, baseline.stderr
assert "CodexBar CLI installed." in baseline.stdout
expected_capture = json.loads(capture.read_text())
assert expected_capture["args"] == ["-", str(helper)]
assert expected_capture["environment"]["PATH"] == environment["PATH"]
# Python/macOS may add locale metadata while starting the stub.
assert set(expected_capture["environment"]) <= {
    "PATH", "LC_CTYPE", "__CF_USER_TEXT_ENCODING",
}, sorted(expected_capture["environment"])

for label, functions, inherited in cases:
    capture.unlink()
    completed = run_installer(functions, inherited)
    assert completed.returncode == 0, (label, completed.stderr)
    assert completed.stdout == baseline.stdout, label
    assert completed.stderr == baseline.stderr, label
    assert json.loads(capture.read_text()) == expected_capture, label

# An approval/installation error must propagate without a success banner.
(temp / "exit-code").write_text("23")
for label, functions, inherited in cases:
    capture.unlink()
    failed = run_installer(functions, inherited)
    assert failed.returncode == 23, (label, failed.stderr)
    assert failed.stdout == "", label
    assert failed.stderr == "", label
    assert json.loads(capture.read_text()) == expected_capture, label
(temp / "exit-code").write_text("0")

# Neither an absent nor a non-executable helper may request approval.
for missing in (False, True):
    capture.unlink(missing_ok=True)
    if missing:
        helper.unlink()
    else:
        helper.chmod(0o644)
    for label, functions, inherited in cases:
        failed = run_installer(functions, inherited)
        assert failed.returncode == 1, (label, failed.stderr)
        assert failed.stderr == (
            f"CodexBarCLI helper not found at {helper}. Please reinstall CodexBar.\n"
        ), label
        assert failed.stdout == "", label
        assert not capture.exists(), label
helper.write_text("#!/bin/sh\nexit 0\n")
helper.chmod(0o755)

# Return the actual AppleScript-generated command; never execute do shell script.
applescript = expected_capture["script"]
approval = "do shell script installCommand with administrator privileges"
assert applescript.count(approval) == 1
capture_script = applescript.replace(approval, "return installCommand")
assert "do shell script" not in capture_script
assert "administrator privileges" not in capture_script
generated = subprocess.run(["/usr/bin/osascript", "-", str(helper)], input=capture_script,
                           env=environment, capture_output=True, text=True, check=True).stdout
assert shlex.split(generated) == [
    "set", "-eu", "/bin/mkdir", "-p", "/usr/local/bin", "/opt/homebrew/bin",
    "/bin/ln", "-sf", str(helper), "/usr/local/bin/codexbar",
    "/bin/ln", "-sf", str(helper), "/opt/homebrew/bin/codexbar",
]

# Run only the captured shell body with both destinations replaced by temp paths.
def local_command(case):
    root = temp / case
    command = generated.replace("/usr/local/bin", shlex.quote(str(root / "local/bin")))
    command = command.replace("/opt/homebrew/bin", shlex.quote(str(root / "homebrew/bin")))
    assert "/usr/local/bin" not in command and "/opt/homebrew/bin" not in command
    return root, command

root, command = local_command("success")
subprocess.run(["/bin/sh", "-c", command], env=environment, check=True)
for prefix in ("local", "homebrew"):
    assert os.readlink(root / prefix / "bin/codexbar") == str(helper)

for tool in ("/bin/mkdir", "/bin/ln"):
    root, command = local_command(Path(tool).name + "-failure")
    command = command.replace(tool, "/usr/bin/false", 1)
    failed = subprocess.run(["/bin/sh", "-c", command], env=environment, capture_output=True)
    assert failed.returncode != 0
    assert not (root / "homebrew/bin/codexbar").is_symlink(), "Continued after an install failure"

print("CLI installer tests passed (nonprivileged command capture and temporary symlinks).")
PY
