#!/usr/bin/env python3
"""Update the tap atomically from the exact published archive checksums."""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
from release import CONFIG, api, metadata, is_prerelease


def rewrite_cask(source, version, digest):
    source, count = re.subn(r'(?m)^  version "[^"]+"$', f'  version "{version}"', source)
    assert count == 1, 'Unexpected cask version layout'
    source, count = re.subn(r'(?m)^  sha256 "[0-9a-f]+"$', f'  sha256 "{digest}"', source)
    assert count == 1, 'Unexpected cask checksum layout'
    return source


def rewrite_formula(source, version, digests):
    source, count = re.subn(r'(?m)^  version "[^"]+"$', f'  version "{version}"', source)
    assert count == 1, 'Unexpected formula version layout'
    pattern = r'(url "https://github.com/steipete/CodexBar/releases/download/v#\{version\}/CodexBarCLI-v#\{version\}-(macos-arm64|macos-x86_64|linux-aarch64|linux-x86_64)\.tar\.gz"\n\s*sha256 ")[0-9a-f]+(")'
    seen = []
    def replace(match):
        target = match[2]
        seen.append(target)
        return match[1] + digests[target] + match[3]
    source = re.sub(pattern, replace, source)
    assert sorted(seen) == sorted(digests), 'Unexpected formula platform layout'
    return source


def main():
    assert os.environ['DRY_RUN'] == 'false', 'No tap writes in dry runs'
    version, _ = metadata()
    assert not is_prerelease(version), 'Prereleases must not replace the stable Homebrew packages'
    tap = 'steipete/homebrew-tap'
    app = CONFIG['app']
    directory = Path('release-assets')
    archive = CONFIG['app_archive'].format(version=version)
    def digest(name):
        return hashlib.sha256((directory / name).read_bytes()).hexdigest()
    expected_digest = digest(archive)
    # The previous job published these exact bytes; verify that identity again.
    published = api(f'repos/{CONFIG["repository"]}/releases/tags/v{version}')
    assert not published['draft'], 'Release must already be public'
    asset = next(a for a in published['assets'] if a['name'] == archive)
    assert asset['digest'] == 'sha256:' + expected_digest, 'Published cask archive digest differs'
    head = api(f'repos/{tap}/git/ref/heads/main')['object']['sha']
    paths = [f'Casks/{app.lower()}.rb']
    if app == 'CodexBar':
        paths.append('Formula/codexbar.rb')
    tree = []
    expected = {}
    for path in paths:
        data = api(f'repos/{tap}/contents/{path}?ref={head}')
        source = base64.b64decode(data['content']).decode()
        if path.startswith('Casks/'):
            updated = rewrite_cask(source, version, expected_digest)
        else:
            digests = {target: digest(f'CodexBarCLI-v{version}-{target}.tar.gz') for target in ['macos-arm64', 'macos-x86_64', 'linux-aarch64', 'linux-x86_64']}
            updated = rewrite_formula(source, version, digests)
        expected[path] = updated
        if updated != source:
            tree.append(dict(path=path, mode='100644', type='blob', content=updated))
    if tree:
        def post(path, value, method='POST'):
            return json.loads(subprocess.check_output(['gh', 'api', path, '--method', method, '--input', '-'], input=json.dumps(value).encode()))
        base_tree = api(f'repos/{tap}/git/commits/{head}')['tree']['sha']
        new_tree = post(f'repos/{tap}/git/trees', dict(base_tree=base_tree, tree=tree))['sha']
        commit = post(f'repos/{tap}/git/commits', dict(message=f'chore: update {app} to {version}', tree=new_tree, parents=[head]))['sha']
        # No force: concurrent tap updates fail instead of overwriting another release.
        post(f'repos/{tap}/git/refs/heads/main', dict(sha=commit, force=False), 'PATCH')
    for path, updated in expected.items():
        data = api(f'repos/{tap}/contents/{path}?ref=main')
        assert base64.b64decode(data['content']).decode() == updated, 'Tap update verification failed'
    subprocess.run(['gh', 'workflow', 'run', 'update-cask-api.yml', '--repo', tap, '--ref', 'main'], check=True)
    print(f'Updated and verified {app} {version} in {tap}')


if __name__ == '__main__':
    main()
