#!/usr/bin/env python3
"""Release policy and publication; builds use the repository's packaging scripts."""
import argparse
import base64
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
CONFIG = json.loads((ROOT / '.github/release.json').read_text())
SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', SPARKLE)


def run(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def api(path, method=None, **fields):
    args = ['gh', 'api', path]
    if method:
        args += ['--method', method]
    for key, value in fields.items():
        args += ['-f', f'{key}={value}']
    return json.loads(run(*args))


def deployment_targets(load_commands):
    """Read only the OS target field; LC_BUILD_VERSION also has tool versions."""
    versions = []
    for block in re.split(r'Load command \d+', load_commands):
        if re.search(r'cmd LC_BUILD_VERSION\b', block):
            field = 'minos'
        elif re.search(r'cmd LC_VERSION_MIN_MACOSX\b', block):
            field = 'version'
        else:
            continue
        match = re.search(r'^\s*' + field + r'\s+(\d+\.\d+(?:\.\d+)?)$', block, re.M)
        assert match, 'Missing deployment target in Mach-O load command'
        versions.append(match[1])
    return versions


def metadata():
    text = (ROOT / 'version.env').read_text()
    values = dict(re.findall(r'^(MARKETING_VERSION|BUILD_NUMBER)=([0-9A-Za-z.-]+)$', text, re.M))
    version = values.get('MARKETING_VERSION', '')
    assert re.fullmatch(r'\d+\.\d+\.\d+(?:-(?:alpha|beta|rc)\.\d+)?', version), 'Expected X.Y.Z or X.Y.Z-beta.N in version.env'
    assert re.fullmatch(r'[1-9]\d*', values.get('BUILD_NUMBER', '')), 'Invalid BUILD_NUMBER'
    return version, values['BUILD_NUMBER']


def is_prerelease(version):
    return '-' in version


def sparkle_channel(version):
    return 'beta' if is_prerelease(version) else None


def notes(version, dry=False):
    text = (ROOT / 'CHANGELOG.md').read_text()
    pattern = r'^## ' + re.escape(version) + r' [—-] (\d{4}-\d{2}-\d{2}|Unreleased)\n(.*?)(?=^## |\Z)'
    matches = list(re.finditer(pattern, text, re.M | re.S))
    assert len(matches) == 1, 'Expected exactly one CHANGELOG section for this version'
    match = matches[0]
    if not dry:
        assert next(re.finditer(r'^## .+$', text, re.M)).group() == match.group().splitlines()[0], 'Release section must be first'
        assert match[1] != 'Unreleased', 'Release notes must be dated'
        date = dt.date.fromisoformat(match[1])
        assert date <= dt.datetime.now(dt.timezone.utc).date(), 'Future changelog date'
    body = match[2].strip()
    assert dry or body, 'Release notes are empty'
    return (body or f'Dry-run build of {version}; no publication.') + '\n'


MARKDOWN_REFERENCE = re.compile(
    r'(?P<code>`+[^`\n]*`+)|(?P<link>\[[^\]\n]*\]\([^\n)]*\))'
    r'|(?P<issue>(?<![\w/])#(?P<number>\d+)\b)'
    r'|(?P<user>(?<![\w.+-])@(?P<username>[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?)(?![A-Za-z0-9-]))'
)


def link_github_references(markdown):
    """Link GitHub references while leaving existing links and code untouched."""
    linked_lines = []
    code_fence = None
    for line in markdown.splitlines(keepends=True):
        fence = re.match(r'^ {0,3}(`{3,}|~{3,})', line)
        if code_fence is not None:
            linked_lines.append(line)
            if fence and fence.group(1)[0] == code_fence[0] and len(fence.group(1)) >= len(code_fence):
                code_fence = None
            continue
        if fence:
            code_fence = fence.group(1)
            linked_lines.append(line)
            continue

        def link_reference(match):
            if match.group('code') or match.group('link'):
                return match.group()
            if match.group('number'):
                number = match.group('number')
                return f'[#{number}](https://github.com/{CONFIG["repository"]}/issues/{number})'
            username = match.group('username')
            return f'[@{username}](https://github.com/{username})'

        linked_lines.append(MARKDOWN_REFERENCE.sub(link_reference, line))
    return ''.join(linked_lines)


def appcast_markdown(version, dry=False):
    """Return the release notes as Markdown for Sparkle's native renderer."""
    title = f'## {CONFIG["app"]} {version}'
    return f'{title}\n\n{link_github_references(notes(version, dry))}'


def add_appcast_description(item, version, dry=False):
    """Add a Sparkle description marked for native Markdown rendering."""
    description = ET.SubElement(item, 'description', {f'{{{SPARKLE}}}format': 'markdown'})
    description.text = appcast_markdown(version, dry)
    return description


def require_ci(sha):
    response = api(f'repos/{CONFIG["repository"]}/actions/workflows/ci.yml/runs?event=push&head_sha={sha}&per_page=50')
    runs = [r for r in response['workflow_runs'] if r['head_sha'] == sha and r['event'] == 'push' and r['head_branch'] == 'main']
    assert runs, 'No push CI run on main for the exact release commit'
    latest = max(runs, key=lambda r: (r['run_number'], r['run_attempt']))
    assert latest['status'] == 'completed' and latest['conclusion'] == 'success', 'Exact-commit push CI is not green'
    return latest['id']


def require_absent(tag):
    # The tag lookup omits drafts. List authenticated releases so a failed draft
    # remains a durable version reservation. Errors and excessive history fail closed.
    for page in range(1, 21):
        releases = api(f'repos/{CONFIG["repository"]}/releases?per_page=100&page={page}')
        assert not any(item['tag_name'] == tag for item in releases), 'This version already has a GitHub Release (including drafts)'
        if len(releases) < 100:
            return
    raise RuntimeError('Could not establish release absence within 20 pages')


def validate():
    dry = os.environ['DRY_RUN'] == 'true'
    version, build = metadata()
    body = notes(version, dry)
    sha = run('git', 'rev-parse', 'HEAD')
    subprocess.run(['git', 'merge-base', '--is-ancestor', sha, 'origin/main'], check=True)
    branch = api(f'repos/{CONFIG["repository"]}/branches/main')
    assert branch['protected'], 'Default branch must be protected'
    if os.environ['GITHUB_EVENT_NAME'] == 'workflow_dispatch':
        assert os.environ['GITHUB_REF'] == 'refs/heads/main', 'Dispatch must use main'
        assert os.environ['GITHUB_SHA'] == branch['commit']['sha'], 'Dispatch must use current main'
    if dry:
        assert sha == branch['commit']['sha'], 'Dry run must prove current protected main'

    tag = f'v{version}'
    if not dry:
        assert os.environ['RELEASE_TAG'] == tag, 'Tag/version mismatch'
        assert run('git', 'cat-file', '-t', f'refs/tags/{tag}') == 'tag', 'Release tag must be annotated'
        assert run('git', 'rev-parse', f'{tag}^{{commit}}') == sha, 'Tag commit mismatch'
        subprocess.run(['git', '-c', 'gpg.format=ssh', '-c', 'gpg.ssh.allowedSignersFile=.github/release-allowed-signers', 'verify-tag', tag], check=True)
        feed = ET.parse(ROOT / 'appcast.xml')
        builds = [int(e.text) for e in feed.findall(f'.//{{{SPARKLE}}}version')]
        assert not builds or int(build) > max(builds), 'BUILD_NUMBER must increase beyond the published feed'
    ci = require_ci(sha)
    Path('release-notes.md').write_text(body)
    data = dict(version=version, build=build, tag=tag, sha=sha, dry_run=str(dry).lower(), ci_run_id=str(ci))
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        for key, value in data.items():
            output.write(f'{key}={value}\n')
    print(f'Validated {tag} at {sha}, push CI {ci}, dry_run={dry}')


def availability():
    assert os.environ["DRY_RUN"] == "false", "Availability job is publication-only"
    version, _ = metadata()
    require_absent(f"v{version}")


def asset_names(version):
    return sorted(name.format(version=version) for name in CONFIG['assets'])


def checksums(directory):
    return ''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in sorted(directory.iterdir()) if p.is_file() and p.name != 'SHA256SUMS')


def inventory():
    directory = Path('release-assets')
    version, _ = metadata()
    payloads = asset_names(version)
    names = payloads + ['appcast.xml', 'RELEASE-NOTES.md']
    # Sidecars are part of the existing public CLI/app asset contract.
    for name in payloads:
        path = directory / name
        assert path.is_file() and not path.is_symlink() and path.stat().st_size > 0, f'Missing asset: {name}'
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        sidecar = directory / (name + '.sha256')
        if sidecar.exists():
            fields = sidecar.read_text().split()
            assert len(fields) == 2 and fields[0] == digest and Path(fields[1].lstrip('*')).name == name, 'Sidecar mismatch'
        sidecar.write_text(f'{digest}  {name}\n')
    names += [name + '.sha256' for name in payloads]
    assert sorted(p.name for p in directory.iterdir()) == sorted(names), 'Release asset inventory mismatch'
    assert all(p.is_file() and not p.is_symlink() and p.stat().st_size > 0 for p in directory.iterdir()), 'Empty or non-file asset'
    assert (directory / 'RELEASE-NOTES.md').read_text() == notes(version, os.environ.get('DRY_RUN') == 'true')
    (directory / 'SHA256SUMS').write_text(checksums(directory))
    print('Verified exact asset inventory and wrote SHA256SUMS')


def appcast():
    """Sign the archive and verify against the embedded public key before publication."""
    import plistlib
    version, build = metadata()
    directory = Path('release-assets')
    archive = directory / CONFIG['app_archive'].format(version=version)
    key_bytes = base64.b64decode(os.environ['SPARKLE_PRIVATE_KEY'].strip(), validate=True)
    assert len(key_bytes) in (32, 96), 'Unexpected Sparkle key format'
    # Legacy Sparkle keys contain a 64-byte expanded secret followed by the public key.
    swift = '''import Foundation
import CryptoKit
let data = Data(base64Encoded: ProcessInfo.processInfo.environment["SPARKLE_PRIVATE_KEY"]!.trimmingCharacters(in: .whitespacesAndNewlines))!
if data.count == 32 {
  let key = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
  print(key.publicKey.rawRepresentation.base64EncodedString())
} else {
  print(data.suffix(32).base64EncodedString())
}
'''
    public_key = run('swift', '-', input=swift)
    plist = plistlib.loads(Path(os.environ['APP_BUNDLE'], 'Contents/Info.plist').read_bytes())
    assert public_key == plist['SUPublicEDKey'] == CONFIG['sparkle_public_key'], 'Sparkle signing key does not match the shipped app'
    with tempfile.TemporaryDirectory() as temp:
        key = Path(temp, 'sparkle.key')
        key.write_text(os.environ['SPARKLE_PRIVATE_KEY'].strip() + '\n')
        key.chmod(0o600)
        signer = os.environ['SPARKLE_SIGN_UPDATE']
        signed = run(signer, '--ed-key-file', str(key), str(archive))
        signature = re.search(r'sparkle:edSignature="([^"]+)"', signed)[1]
        subprocess.run([signer, '--ed-key-file', str(key), '--verify', str(archive), signature], check=True)
    tree = ET.parse(ROOT / 'appcast.xml')
    channel = tree.getroot().find('channel')
    for item in list(channel.findall('item')):
        if item.findtext(f'{{{SPARKLE}}}version') == build:
            channel.remove(item)
    item = ET.Element('item')
    if sparkle_channel(version):
        ET.SubElement(item, f'{{{SPARKLE}}}channel').text = sparkle_channel(version)
    ET.SubElement(item, 'title').text = version
    ET.SubElement(item, 'pubDate').text = dt.datetime.now(dt.timezone.utc).strftime('%a, %d %b %Y %H:%M:%S +0000')
    ET.SubElement(item, f'{{{SPARKLE}}}version').text = build
    ET.SubElement(item, f'{{{SPARKLE}}}shortVersionString').text = version
    ET.SubElement(item, f'{{{SPARKLE}}}minimumSystemVersion').text = CONFIG['minimum_macos']
    if CONFIG['architectures'] == ['arm64']:
        ET.SubElement(item, f'{{{SPARKLE}}}hardwareRequirements').text = 'arm64'
    add_appcast_description(item, version, os.environ.get('DRY_RUN') == 'true')
    ET.SubElement(item, 'enclosure', {'url': f'https://github.com/{CONFIG["repository"]}/releases/download/v{version}/{archive.name}', 'length': str(archive.stat().st_size), 'type': 'application/octet-stream', f'{{{SPARKLE}}}edSignature': signature})
    channel.insert(0, item)
    ET.indent(tree)
    tree.write(directory / 'appcast.xml', encoding='utf-8', xml_declaration=True)


def publish():
    assert os.environ['DRY_RUN'] == 'false', 'Publication is disabled for dry runs'
    version, _ = metadata()
    tag = f'v{version}'
    sha = os.environ['RELEASE_SHA']
    require_ci(sha)
    require_absent(tag)
    remote_tag = api(f'repos/{CONFIG["repository"]}/git/ref/tags/{tag}')
    assert remote_tag['object']['type'] == 'tag' and remote_tag['object']['sha'] == run('git', 'rev-parse', f'refs/tags/{tag}'), 'Remote tag changed'
    current_feed = api(f'repos/{CONFIG["repository"]}/contents/appcast.xml?ref=main')
    assert base64.b64decode(current_feed['content']) == (ROOT / 'appcast.xml').read_bytes(), 'Feed advanced since this release commit'
    assert run('git', 'rev-parse', f'{tag}^{{commit}}') == sha
    subprocess.run(['git', '-c', 'gpg.format=ssh', '-c', 'gpg.ssh.allowedSignersFile=.github/release-allowed-signers', 'verify-tag', tag], check=True)
    directory = Path('release-assets')
    assert sorted(p.name for p in directory.iterdir()) == sorted(asset_names(version) + [n + '.sha256' for n in asset_names(version)] + ['appcast.xml', 'RELEASE-NOTES.md', 'SHA256SUMS'])
    assert (directory / 'SHA256SUMS').read_text() == checksums(directory), 'Artifact checksum mismatch'
    assert (directory / 'RELEASE-NOTES.md').read_text() == notes(version)
    create = ['gh', 'release', 'create', tag, '--repo', CONFIG['repository'], '--draft', '--verify-tag', '--title', f'{CONFIG["app"]} {version}', '--notes-file', str(directory / 'RELEASE-NOTES.md')]
    if is_prerelease(version):
        create.append('--prerelease')
    subprocess.run([*create, *map(str, sorted(directory.iterdir()))], check=True)
    # Verify the uploaded bytes, not just the local artifacts, before making the draft public.
    with tempfile.TemporaryDirectory() as temp:
        subprocess.run(['gh', 'release', 'download', tag, '--repo', CONFIG['repository'], '--dir', temp], check=True)
        downloaded = Path(temp)
        assert sorted(p.name for p in downloaded.iterdir()) == sorted(p.name for p in directory.iterdir())
        assert all((downloaded / p.name).read_bytes() == p.read_bytes() for p in directory.iterdir())
    subprocess.run(['gh', 'release', 'edit', tag, '--repo', CONFIG['repository'], '--draft=false', f'--latest={str(not is_prerelease(version)).lower()}'], check=True)
    # Keep the historical feed URL: existing installed clients read main/appcast.xml.
    current = api(f'repos/{CONFIG["repository"]}/contents/appcast.xml?ref=main')
    assert current['sha'] == current_feed['sha'], 'Feed changed during publication; finish feed handoff from the verified release'
    api(f'repos/{CONFIG["repository"]}/contents/appcast.xml', method='PUT', message=f'chore: publish {tag} update feed', content=base64.b64encode((directory / 'appcast.xml').read_bytes()).decode(), sha=current['sha'], branch='main')
    after = api(f'repos/{CONFIG["repository"]}/contents/appcast.xml?ref=main')
    assert base64.b64decode(after['content']) == (directory / 'appcast.xml').read_bytes(), 'Published appcast differs'


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['validate', 'availability', 'inventory', 'appcast', 'publish'])
    globals()[parser.parse_args().command]()
