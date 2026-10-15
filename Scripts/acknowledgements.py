#!/usr/bin/env python3
"""Generate/check bundled notices. Refresh downloads only immutable upstream sources."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
RESOURCE = Path('Sources/CodexBarCore/Resources/Acknowledgements.json')
LOCKS = [Path('Package.resolved'), Path(
    'WidgetExtension/CodexBarWidgetExtension.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved')]
# All resolved packages are intentional, including platform-conditional/transitive products.
PACKAGES = {
    'commander': ('Commander', ['Peter Steinberger'], 'MIT', ['LICENSE']),
    'keyboardshortcuts': ('KeyboardShortcuts', ['Sindre Sorhus'], 'MIT', ['license']),
    'sparkle': ('Sparkle', ['Andy Matuschak', 'Elgato Systems GmbH', 'Kornel Lesiński',
                           'Mayur Pawashe', 'C.W. Betts', 'Petroules Corporation', 'Big Nerd Ranch'],
                'MIT / BSD / zlib', ['LICENSE', 'Vendor/ed25519-sparkle/license.txt']),
    'sweetcookiekit': ('SweetCookieKit', ['Peter Steinberger'], 'MIT', ['LICENSE']),
    'swift-asn1': ('swift-asn1', ['The SwiftASN1 Project'], 'Apache-2.0', ['NOTICE.txt', 'LICENSE.txt']),
    'swift-crypto': ('swift-crypto', ['The SwiftCrypto Project'], 'Apache-2.0', ['NOTICE.txt', 'LICENSE.txt']),
    'swift-log': ('swift-log', ['The SwiftLog Project'], 'Apache-2.0', ['NOTICE.txt', 'LICENSE.txt']),
    'vortex': ('Vortex', ['Paul Hudson'], 'MIT', ['LICENSE']),
}
SUCRASE_SHA256 = '4d997e15b72cbc9ccf6e743c30c6eb48bf4533f6709852367b40766be5eba70b'

# These versions reproduce the checked-in Sucrase bundle, including its transitive imports.
NPM = {
    'sucrase': '3.35.1',
    '@jridgewell/gen-mapping': '0.3.13',
    '@jridgewell/resolve-uri': '3.1.2',
    '@jridgewell/sourcemap-codec': '1.5.5',
    '@jridgewell/trace-mapping': '0.3.31',
    'lines-and-columns': '1.2.4',
    'ts-interface-checker': '0.1.13',
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def download(url):
    # Bound the whole transfer, including DNS and retries across resolved addresses.
    return subprocess.check_output(
        ['curl', '--fail', '--location', '--silent', '--show-error',
         '--connect-timeout', '20', '--max-time', '120', url], timeout=130)


def archive_files(data):
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        return {member.name.split('/', 1)[1]: archive.extractfile(member).read()
                for member in archive.getmembers() if member.isfile() and '/' in member.name}


def pins(root):
    result = {}
    for lock in LOCKS:
        for pin in json.loads((root / lock).read_text())['pins']:
            key = pin['identity']
            value = (pin['location'].removesuffix('.git'), pin['state']['revision'])
            if key in result and result[key] != value:
                raise ValueError(f'{key}: root/widget pins disagree')
            result[key] = value
    if result.keys() != PACKAGES.keys():
        raise ValueError(f'Update PACKAGES for resolved dependency changes: {result.keys() ^ PACKAGES.keys()}')
    return result


def source(path, data):
    return {'path': path, 'sha256': digest(data), 'text': data.decode('utf-8')}


def entry(name, authors, url, license_name, sources, **extra):
    return dict(name=name, authors=authors, url=url, license=license_name, sources=sources, **extra)


def header_notices(files, prefix):
    # Preserve verbatim copyright/permission blocks, including Unicode and BSD headers.
    seen = set()
    result = []
    for path, data in sorted(files.items()):
        if not path.startswith(prefix) or not path.endswith(('.c', '.h', '.cc')):
            continue
        for block in re.findall(rb'/\*.*?\*/', data[:6000], flags=re.S):
            if b'copyright' not in block.lower() or block in seen:
                continue
            seen.add(block)
            result.append(source(path, block))
    return result


def generate(root):
    entries = []
    for identity, (url, revision) in sorted(pins(root).items()):
        files = archive_files(download(f'https://codeload.github.com/{url.split("github.com/")[1]}/tar.gz/{revision}'))
        name, authors, license_name, paths = PACKAGES[identity]
        entries.append(entry(name, authors, url, license_name,
                             [source(path, files[path]) for path in paths], identity=identity, revision=revision))
        if identity == 'swift-crypto':
            revision_match = re.search(rb'revision ([0-9a-f]{40})', files['Sources/CCryptoBoringSSL/hash.txt'])
            boring_revision = revision_match[1].decode()
            boring = archive_files(download(f'https://codeload.github.com/google/boringssl/tar.gz/{boring_revision}'))
            entries.append(entry('BoringSSL', ['The BoringSSL Authors'], 'https://github.com/google/boringssl',
                                 'Apache-2.0 / ISC / BSD', [source(path, boring[path]) for path in ['LICENSE', 'third_party/fiat/LICENSE']],
                                 revision=boring_revision))
            entries.append(entry('XKCP', ['The Keccak Team', 'Brian Gladman'], 'https://github.com/XKCP/XKCP',
                                 'CC0-1.0 / BSD', header_notices(files, 'Sources/CXKCP/'), revision=revision))
    quickjs = {str(p.relative_to(root)): p.read_bytes() for p in (root / 'Sources/CQuickJS').rglob('*') if p.is_file()}
    entries.append(entry('QuickJS', ['Fabrice Bellard', 'Charlie Gordon', 'Ben Noordhuis', 'Saúl Ibarra Corretgé'],
                         'https://github.com/quickjs-ng/quickjs', 'MIT / Unicode-3.0',
                         [source('Sources/CQuickJS/LICENSE', quickjs['Sources/CQuickJS/LICENSE'])]
                         + header_notices(quickjs, 'Sources/CQuickJS/')))
    for name, version in NPM.items():
        basename = name.split('/')[-1]
        files = archive_files(download(f'https://registry.npmjs.org/{name}/-/{basename}-{version}.tgz'))
        info = json.loads(files['package.json'])
        authors = info.get('author', 'Various contributors')
        if isinstance(authors, dict):
            authors = authors['name']
        paths = sorted(path for path in files if '/' not in path and path.lower().startswith(('license', 'notice')))
        if not paths:
            raise ValueError(f'{name}: no upstream license')
        entries.append(entry('Sucrase' if name == 'sucrase' else name, [authors],
                             f'https://www.npmjs.com/package/{name}', info['license'],
                             [source(path, files[path]) for path in paths], npm=name, revision=version))
    return sorted(entries, key=lambda item: item['name'].lower())


def check(root, entries):
    resolved = pins(root)
    bundle = root / 'Sources/CodexBarCore/Resources/Plugins/sucrase-3.35.1.min.js'
    if digest(bundle.read_bytes()) != SUCRASE_SHA256:
        raise ValueError('Sucrase bundle changed; audit and regenerate its dependency notices')
    actual = {item['identity']: (item['url'], item['revision']) for item in entries if 'identity' in item}
    if actual != resolved:
        raise ValueError('Acknowledgements do not match root/widget pins; run Scripts/acknowledgements.py --write')
    npm = {item['npm']: item['revision'] for item in entries if 'npm' in item}
    if npm != NPM or not {'QuickJS', 'BoringSSL', 'XKCP'}.issubset(item['name'] for item in entries):
        raise ValueError('Vendored dependency acknowledgement is missing')
    for item in entries:
        if not item['sources']:
            raise ValueError(f'{item["name"]}: no notices')
        for notice in item['sources']:
            data = notice['text'].encode('utf-8')
            if not data or digest(data) != notice['sha256']:
                raise ValueError(f'{item["name"]}: notice changed')
            if item['name'] == 'QuickJS':
                original = (root / notice['path']).read_bytes()
                if data not in original:
                    raise ValueError(f'{notice["path"]}: vendored notice drifted')
    if 'UNICODE LICENSE V3' not in json.dumps(entries) or 'Brian Gladman' not in json.dumps(entries):
        raise ValueError('Unicode or XKCP BSD notice is missing')


def render(entries):
    return 'CodexBar — Third-party notices\n\n' + '\n\n'.join(
        f'{item["name"]} ({item["license"]})\n{item["url"]}\n\n' + '\n\n'.join(
            f'--- {notice["path"]} ---\n{notice["text"]}' for notice in item['sources']) for item in entries) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write', action='store_true', help='Regenerate from pinned upstream sources (network)')
    parser.add_argument('--verify-upstream', action='store_true', help='Compare with pinned upstream sources (network)')
    parser.add_argument('--text-output', type=Path, help='Export the checked notices for release packaging')
    args = parser.parse_args()
    if args.write:
        entries = generate(ROOT)
        (ROOT / RESOURCE).write_text(json.dumps(entries, ensure_ascii=False, indent=2) + '\n')
    else:
        entries = json.loads((ROOT / RESOURCE).read_text())
    check(ROOT, entries)
    if args.verify_upstream and entries != generate(ROOT):
        raise ValueError('Bundled notices differ from pinned upstream sources')
    if args.text_output:
        args.text_output.write_text(render(entries))
    print(f'Acknowledgements OK: {len(entries)} components; root/widget pins and vendored notices checked')


if __name__ == '__main__':
    main()
