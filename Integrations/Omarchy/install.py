#!/usr/bin/env python3
"""Compatibility entry point: install the desktop app and thin Omarchy adapter."""
import argparse
from pathlib import Path
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--executable', required=True, help='CodexBar Linux CLI')
parser.add_argument('--desktop-binary')
parser.add_argument('--provider')
args = parser.parse_args()
command = [sys.executable, str(Path(__file__).resolve().parents[1] / 'Linux/install.py'),
           '--omarchy', '--cli', args.executable]
if args.desktop_binary:
    command.extend(['--binary', args.desktop_binary])
if args.provider:
    command.extend(['--provider', args.provider])
raise SystemExit(subprocess.call(command))
