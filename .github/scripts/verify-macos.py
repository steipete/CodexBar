#!/usr/bin/env python3
"""Verify the release bundle, deployment targets, and launch on the build runner."""
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import time
from release import deployment_targets

config = json.loads(Path('.github/release.json').read_text())
app = Path(sys.argv[1]).resolve()
plist = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
version = dict(re.findall(r'^(\w+)=(.+)$', Path('version.env').read_text(), re.M))
assert plist['CFBundleIdentifier'] == config['bundle_id']
assert plist['CFBundleShortVersionString'] == version['MARKETING_VERSION']
assert plist['CFBundleVersion'] == version['BUILD_NUMBER']
assert plist['LSMinimumSystemVersion'] == config['minimum_macos']
assert plist['SUPublicEDKey'] == config['sparkle_public_key']
assert plist['SUFeedURL'] == f'https://raw.githubusercontent.com/{config["repository"]}/main/appcast.xml'
main = app / 'Contents/MacOS' / config['app']
required = set(config['architectures'])
assert set(subprocess.check_output(['lipo', '-archs', str(main)], text=True).split()) == required
limit = tuple(map(int, config['minimum_macos'].split('.')))
seen = set()
for path in app.rglob('*'):
    if not path.is_file() or path.resolve() in seen:
        continue
    seen.add(path.resolve())
    if 'Mach-O' not in subprocess.check_output(['file', '-b', str(path)], text=True):
        continue
    architectures = set(subprocess.check_output(['lipo', '-archs', str(path)], text=True).split())
    assert required <= architectures, f'{path}: missing architecture'
    for arch in required:
        load = subprocess.check_output(['otool', '-arch', arch, '-l', str(path)], text=True)
        minima = deployment_targets(load)
        assert minima, f'{path}: no deployment target for {arch}'
        assert all(tuple(map(int, m.split('.')[:2])) <= limit for m in minima), f'{path}: deployment target exceeds {limit}: {minima}'
subprocess.run(['codesign', '--verify', '--deep', '--strict', '-R', f'=anchor apple generic and certificate leaf[subject.OU] = "Y5PE65HELJ" and identifier "{config["bundle_id"]}"', str(app)], check=True)
subprocess.run(['spctl', '--assess', '--type', 'execute', '--verbose=2', str(app)], check=True)
subprocess.run(['xcrun', 'stapler', 'validate', str(app)], check=True)
# Verify the separately shipped dSYM belongs to this exact app executable.
with tempfile.TemporaryDirectory() as temp:
    archive = Path('release-assets') / config['dsym_archive'].format(version=version['MARKETING_VERSION'])
    subprocess.run(['ditto', '-x', '-k', str(archive), temp], check=True)
    dwarf = Path(temp, config['app'] + '.dSYM/Contents/Resources/DWARF', config['app'])
    def uuids(path):
        return set(re.findall(r'UUID: ([A-Fa-f0-9-]+) \(([^)]+)\)', subprocess.check_output(['dwarfdump', '--uuid', str(path)], text=True)))
    assert uuids(main) and uuids(main) == uuids(dwarf), 'dSYM UUID mismatch'
if config['app'] == 'CodexBar':
    env = dict(os.environ, CODEXBAR_RESOURCE_SMOKE='1')
    for arch in sorted(required):
        result = subprocess.run(['arch', '-' + arch, str(app / 'Contents/Helpers/CodexBarCLI')], env=env, text=True, capture_output=True, timeout=30)
        assert result.returncode == 0 and 'CODEXBAR_RESOURCE_SMOKE_OK' in result.stdout, f'Bundled CLI resources failed for {arch}'
    # The upstream packager owns the release capabilities; ensure they survived signing.
    entitlements = plistlib.loads(subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(app)], stderr=subprocess.DEVNULL))
    assert entitlements['com.apple.developer.icloud-container-identifiers'] == ['iCloud.com.steipete.codexbar']
    assert (app / 'Contents/embedded.provisionprofile').is_file()
    assert (app / 'Contents/PlugIns/CodexBarWidget.appex').is_dir()
assert os.environ.get('CI') == 'true', 'Launch verification is only for a fresh CI runner'
for arch in sorted(required):
    with tempfile.TemporaryDirectory() as home:
        environment = dict(os.environ, HOME=home, CFFIXED_USER_HOME=home)
        for name in [
            'SPARKLE_PRIVATE_KEY',
            'GH_TOKEN',
            'GITHUB_TOKEN',
            'MACOS_SIGNING_P12',
            'MACOS_SIGNING_P12_PASSWORD',
            'APP_STORE_CONNECT_API_KEY_P8',
        ]:
            environment.pop(name, None)
        process = subprocess.Popen(['arch', '-' + arch, str(main)], env=environment)
        try:
            time.sleep(8)
            assert process.poll() is None, f'App exited during {arch} launch smoke test'
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
print('Verified metadata, architectures, all Mach-O minimum OS versions, signing, notarization, and launch')
