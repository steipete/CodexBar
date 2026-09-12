#!/usr/bin/env python3
"""Connect the native Omarchy bar adapter to the Rust experiment, with a backup."""
import argparse
import datetime
import json
import os
from pathlib import Path
import shutil
import stat

ROOT = Path(__file__).resolve().parent
ADAPTER = ROOT.parents[1] / 'Omarchy'


def install(config_home, binary):
    binary = binary.resolve()
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError('Build the Rust prototype first, or pass --binary PATH.')
    shell = config_home / 'omarchy/shell.json'
    config = json.loads(shell.read_text())
    layout = config.get('bar', {}).get('layout', {})
    if not isinstance(layout, dict) or not isinstance(layout.get('right'), list):
        raise ValueError('Expected an existing Omarchy bar layout in shell.json.')
    found = False
    for section in ['left', 'center', 'right']:
        for index, entry in enumerate(layout.get(section, [])):
            identifier = entry if isinstance(entry, str) else entry.get('id')
            if identifier == 'steipete.codexbar':
                if isinstance(entry, str):
                    entry = {'id': identifier}
                    layout[section][index] = entry
                entry['desktopExecutable'] = str(binary)
                found = True
            elif identifier == 'omarchy.tray' and isinstance(entry, dict):
                entry['pinned'] = [item for item in entry.get('pinned', []) if item != 'codexbar-rust-prototype']
    if not found:
        layout['right'].insert(0, {'id': 'steipete.codexbar', 'desktopExecutable': str(binary)})

    plugin = config_home / 'omarchy/plugins/steipete.codexbar'
    if plugin.is_symlink():
        raise ValueError('The existing adapter is a symlink; choose a regular user plugin directory.')
    backup = config_home / 'codexbar-rust-prototype/backups' / datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    backup.mkdir(parents=True)
    shutil.copy2(shell, backup / 'shell.json')
    if plugin.exists():
        shutil.copytree(plugin, backup / 'steipete.codexbar')
    plugin.mkdir(parents=True, exist_ok=True)
    for name in ['Panel.qml', 'manifest.json']:
        shutil.copy2(ADAPTER / name, plugin / name)
    temporary = shell.with_name('shell.json.codexbar-rust-tmp')
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, stat.S_IMODE(shell.stat().st_mode))
    with os.fdopen(descriptor, 'w') as output:
        output.write(json.dumps(config, indent=2) + '\n')
    temporary.replace(shell)
    return backup


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=ROOT / 'target/debug/codexbar-rust-prototype')
    parser.add_argument('--config-home', type=Path, default=Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config')))
    args = parser.parse_args()
    try:
        backup = install(args.config_home, args.binary)
    except (OSError, ValueError) as error:
        parser.exit(1, f'{error}\n')
    print(f'Omarchy adapter now uses the Rust prototype. Backup: {backup}')
    print(f'Run the backend with: {args.binary.resolve()} --background --no-tray')
