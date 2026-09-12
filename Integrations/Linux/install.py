#!/usr/bin/env python3
"""Install the Linux desktop app, launcher and optional Omarchy adapter for this user."""
import argparse
import datetime
import json
import os
from pathlib import Path
import shutil
import tempfile

REPO = Path(__file__).resolve().parents[2]
APP_ID = 'com.steipete.CodexBar'
PLUGIN_ID = 'steipete.codexbar'


def atomic(path, content, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as handle:
        temporary = Path(handle.name)
        handle.write(content)
        handle.flush()
        os.fsync(handle.fileno())
    temporary.chmod(mode)
    temporary.replace(path)


def quoted(path):
    text = str(path).replace('%', '%%')
    for character in ['\\', '"', '`', '$']:
        text = text.replace(character, '\\' + character)
    return '"' + text + '"'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=REPO / ('bin/codexbar-linux' if (REPO / 'bin/codexbar-linux').exists() else '.local/linux-build/codexbar-linux'))
    parser.add_argument('--cli', type=Path)
    parser.add_argument('--omarchy', action='store_true')
    parser.add_argument('--no-autostart', action='store_true')
    parser.add_argument('--provider')
    args = parser.parse_args()
    binary = args.binary.resolve()
    if not binary.is_file() or not os.access(binary, os.X_OK):
        parser.error('Build codexbar-linux first, or pass --binary')
    config = Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config'))
    data = Path(os.environ.get('XDG_DATA_HOME', Path.home() / '.local/share'))
    shell_path = config / 'omarchy/shell.json'
    shell = json.loads(shell_path.read_text()) if args.omarchy else None
    existing = None
    if shell is not None:
        for section in shell.get('bar', {}).get('layout', {}).values():
            for entry in section:
                if isinstance(entry, dict) and entry.get('id') == PLUGIN_ID:
                    existing = entry
    preferences = config / 'codexbar/linux.json'
    settings = json.loads(preferences.read_text()) if preferences.exists() else {}
    if not preferences.exists() and existing:
        keys = ['executable', 'provider', 'source', 'accountIndex', 'allAccounts', 'showIdentity',
                'refreshSeconds', 'showCosts', 'showStatus', 'notifications', 'notifyThreshold']
        settings.update({key: existing[key] for key in keys if key in existing})
    cli = args.cli or settings.get('executable') or shutil.which('codexbar')
    if not cli:
        candidate = REPO / '.local/omarchy-cli/codexbar'
        if candidate.exists():
            cli = candidate
    if cli and not Path(cli).is_absolute():
        cli = shutil.which(str(cli)) or cli
    if not cli or not Path(cli).is_file() or not os.access(cli, os.X_OK):
        parser.error('Pass --cli with an installed CodexBar Linux CLI executable')
    settings['executable'] = str(Path(cli).resolve())
    settings.setdefault('provider', 'codex')
    if args.provider:
        settings['provider'] = args.provider
    if args.omarchy:
        settings['showTray'] = False
        settings.setdefault('followOmarchyTheme', True)
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    if preferences.exists():
        shutil.copy2(preferences, preferences.with_name(f'linux.json.backup-{stamp}'))
    atomic(preferences, (json.dumps(settings, indent=2) + '\n').encode())
    destination = Path.home() / '.local/bin/codexbar-linux'
    atomic(destination, binary.read_bytes(), 0o755)
    icon = data / 'icons/hicolor/scalable/apps/codexbar.svg'
    atomic(icon, (REPO / 'Integrations/Linux/icon.svg').read_bytes(), 0o644)
    launcher = f'''[Desktop Entry]
Type=Application
Name=CodexBar
Comment=AI usage, accounts and local spending
Exec={quoted(destination)} --usage
Icon=codexbar
Terminal=false
Categories=Utility;Development;
StartupWMClass=com.steipete.CodexBar
Actions=Settings;Spending;

[Desktop Action Settings]
Name=Settings
Exec={quoted(destination)} --settings

[Desktop Action Spending]
Name=Usage & Spend
Exec={quoted(destination)} --spending
'''
    atomic(data / f'applications/{APP_ID}.desktop', launcher.encode(), 0o644)
    startup_path = config / f'autostart/{APP_ID}.desktop'
    startup_disabled = args.no_autostart or (startup_path.exists() and 'Hidden=true' in startup_path.read_text())
    startup = f'''[Desktop Entry]
Type=Application
Name=CodexBar
Exec={quoted(destination)} --background
Icon=codexbar
Terminal=false
Hidden={'true' if startup_disabled else 'false'}
'''
    atomic(config / f'autostart/{APP_ID}.desktop', startup.encode(), 0o644)
    if args.omarchy:
        plugin = config / 'omarchy/plugins' / PLUGIN_ID
        if plugin.exists():
            backup = config / 'omarchy/backups' / f'{PLUGIN_ID}-{stamp}'
            backup.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(plugin), backup)
        plugin.mkdir(parents=True)
        for name in ['manifest.json', 'Panel.qml']:
            shutil.copy2(REPO / 'Integrations/Omarchy' / name, plugin / name)
        shutil.copy2(shell_path, shell_path.with_name(f'shell.json.codexbar-backup-{stamp}'))
        if existing is None:
            existing = {'id': PLUGIN_ID}
            shell.setdefault('bar', {}).setdefault('layout', {}).setdefault('right', []).insert(0, existing)
        # Provider/app settings now belong exclusively to CodexBar.
        for key in list(existing):
            if key not in ['id', 'desktopExecutable']:
                existing.pop(key)
        existing['desktopExecutable'] = str(destination)
        atomic(shell_path, (json.dumps(shell, indent=2) + '\n').encode(), shell_path.stat().st_mode & 0o777)
    print(f'Installed {destination}')
    print('Run codexbar-linux --settings, or open CodexBar from the application launcher.')


if __name__ == '__main__':
    main()
