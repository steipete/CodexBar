"""Check the shipped executable, its provider list and resources outside the checkout."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
app = root / 'CodexBar.app'
with tempfile.TemporaryDirectory(prefix='codexbar-personal-resources-') as folder:
    copy = Path(folder) / 'CodexBar.app'
    subprocess.run(['ditto', str(app), str(copy)], check=True)
    contents = copy / 'Contents'
    binary = contents / 'MacOS/CodexBar'
    executables = {p for p in contents.rglob('*') if p.is_file() and p.stat().st_mode & 0o111}
    if executables != {binary} or not (contents / 'Resources/Icon.icns').is_file():
        raise SystemExit('Personal bundle has unexpected executables or is missing its icon')
    profile = '(version 1)(allow default)(deny network*)(deny file-read* (subpath "' + str(root) + '"))'
    result = subprocess.run(['sandbox-exec', '-p', profile, str(binary), '--list-subscriptions'],
                            cwd=folder, capture_output=True, text=True, check=True, timeout=15)
    if result.stdout.splitlines() != ['codex', 'kimi', 'antigravity']:
        raise SystemExit(f'Unexpected compiled subscriptions: {result.stdout!r}')
    print('Verified standalone CodexBar, icon, and compiled subscriptions: codex, kimi, antigravity')
