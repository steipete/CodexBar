#!/usr/bin/env python3
"""Install this checkout's plugin and preserve the existing Omarchy layout."""
import argparse
import datetime
import json
import os
from pathlib import Path
import shutil
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--executable', required=True, type=Path)
parser.add_argument('--provider', default='codex')
args = parser.parse_args()
executable = args.executable.resolve()
if not executable.is_file() or not os.access(executable, os.X_OK):
    parser.error('--executable must be an executable CodexBar Linux CLI')
config = Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config')) / 'omarchy'
shell = config / 'shell.json'
data = json.loads(shell.read_text())
plugin_id = 'steipete.codexbar'
destination = config / 'plugins' / plugin_id
source = Path(__file__).resolve().parent
stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
shutil.copy2(shell, shell.with_name(f'shell.json.codexbar-backup-{stamp}'))
if destination.exists():
    backup = config / 'backups' / f'{plugin_id}-{stamp}'
    backup.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(destination, backup)
destination.mkdir(parents=True, exist_ok=True)
for name in ['manifest.json', 'Panel.qml', 'Usage.js']:
    shutil.copy2(source / name, destination / name)
entry = None
layout = data.setdefault('bar', {}).setdefault('layout', {})
for section in layout.values():
    if not isinstance(section, list):
        continue
    for existing in section:
        if isinstance(existing, dict) and existing.get('id') == plugin_id:
            entry = existing
if entry is None:
    entry = {'id': plugin_id}
    layout.setdefault('right', []).insert(0, entry)
entry.update(executable=str(executable), provider=args.provider, refreshSeconds=300)
with tempfile.NamedTemporaryFile(mode='w', dir=config, delete=False) as handle:
    temporary = Path(handle.name)
    json.dump(data, handle, indent=2)
    handle.write('\n')
    handle.flush()
    os.fsync(handle.fileno())
temporary.chmod(shell.stat().st_mode & 0o777)
temporary.replace(shell)
print(f'Installed {destination}; Omarchy will hot-reload the widget.')
