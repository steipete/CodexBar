#!/usr/bin/env python3
"""Package a built Linux desktop app without bundling credentials or a provider CLI."""
import argparse
import platform
from pathlib import Path
import re
import tarfile

REPO = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=REPO / '.local/linux-build/codexbar-linux')
    parser.add_argument('--version', required=True)
    parser.add_argument('--output', type=Path, default=REPO / '.local/packages')
    args = parser.parse_args()
    if not re.fullmatch(r'[0-9][a-zA-Z0-9._-]{0,79}', args.version):
        parser.error('Version must start with a digit and contain only letters, numbers, dots, underscores and hyphens')
    if not args.binary.is_file():
        parser.error('Build the desktop app first, or supply --binary')
    architecture = {'x86_64': 'x86_64', 'aarch64': 'aarch64', 'arm64': 'aarch64'}.get(platform.machine())
    if architecture is None:
        parser.error('Supported architectures: x86_64 and aarch64')
    name = f'CodexBarDesktop-v{args.version}-linux-{architecture}'
    args.output.mkdir(parents=True, exist_ok=True)
    destination = args.output / f'{name}.tar.gz'
    files = {
        'bin/codexbar-linux': args.binary,
        'README.md': REPO / 'Integrations/Linux/README.md',
        'LICENSE': REPO / 'LICENSE',
    }
    for path in ['Integrations/Linux/install.py', 'Integrations/Linux/icon.svg',
                 'Integrations/Omarchy/Panel.qml', 'Integrations/Omarchy/manifest.json']:
        files[path] = REPO / path
    # Explicit allowlist: never archive the checkout, user config, or local CLI resource tree.
    with tarfile.open(destination, 'w:gz') as archive:
        for relative, source in files.items():
            info = archive.gettarinfo(str(source), arcname=f'{name}/{relative}')
            info.uid = info.gid = 0
            info.uname = info.gname = ''
            info.mode = 0o755 if relative == 'bin/codexbar-linux' else 0o644
            with source.open('rb') as content:
                archive.addfile(info, content)
    print(destination)


if __name__ == '__main__':
    main()
