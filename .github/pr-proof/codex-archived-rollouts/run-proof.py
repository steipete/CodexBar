#!/usr/bin/env python3
"""Synthetic before/after proof for Codex rollouts archived as .jsonl.zst (#4523).

Builds a fictitious CODEX_HOME, then runs `codexbar cost --provider codex --days 30 --refresh` with
an isolated HOME for each scenario until totals repeat. Only fixture data is used; output holds no
personal paths, accounts or usage.

    run-proof.py --base <0.75.0 CodexBarCLI> --head <this branch's CodexBarCLI> --out <dir>
    run-proof.py --upgrade-base 0.77.0=<0.77.0 CodexBarCLI> --head <this branch's CodexBarCLI> --out <dir>

Each --upgrade-base adds an "upgrade from <version> cache" result; without --base, the other results already in
<dir>/proof.json are kept.
"""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile

TODAY = dt.datetime.now().astimezone().replace(hour=12, minute=0, second=0, microsecond=0)


def uid(n):
    return f'0199f0a0-0000-7000-8000-{n:012d}'


def stamp(day):
    return day.astimezone(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z')


def meta(sid, day, parent=None):
    payload = {'id': sid, 'source': 'vscode', 'thread_source': 'user', 'timestamp': stamp(day)}
    if parent:
        payload['forked_from_id'] = parent
    return {'type': 'session_meta', 'payload': payload}


def tokens(day, total, last):
    return {'type': 'event_msg', 'timestamp': stamp(day), 'payload': {'type': 'token_count', 'info': {
        'model': 'gpt-5.4',
        'total_token_usage': {'input_tokens': total, 'output_tokens': 0},
        'last_token_usage': {'input_tokens': last, 'output_tokens': 0}}}}


def rollout(sid, day, totals, parent=None):
    lines = [meta(sid, day, parent), {'type': 'turn_context', 'timestamp': stamp(day), 'payload': {'model': 'gpt-5.4'}}]
    previous = 0
    for offset, total in enumerate(totals, start=1):
        lines.append(tokens(day + dt.timedelta(seconds=offset), total, total - previous))
        previous = total
    return ''.join(json.dumps(line) + '\n' for line in lines)


def write(home, rel, text, day, form):
    """form: plain | archive | both | corrupt"""
    path = home / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    if form != 'plain':
        subprocess.run(['zstd', '-q', '-19', '-f', str(path), '-o', str(path) + '.zst'], check=True)
        if form == 'corrupt':
            data = Path(str(path) + '.zst').read_bytes()
            Path(str(path) + '.zst').write_bytes(data[:-6])
        if form in ('archive', 'corrupt'):
            path.unlink()
    for target in [path, Path(str(path) + '.zst')]:
        if target.exists():
            os.utime(target, (day.timestamp(), day.timestamp()))


def day_path(day, sid):
    return f'sessions/{day:%Y/%m/%d}/rollout-{day:%Y-%m-%dT%H-%M-%S}-{sid}.jsonl'


def build_fixture(home, include_corrupt=True):
    cases = []

    def add(name, n, days_ago, form, totals, parent=None, flat=False):
        day = TODAY - dt.timedelta(days=days_ago)
        sid = uid(n)
        rel = (f'archived_sessions/rollout-{day:%Y-%m-%dT%H-%M-%S}-{sid}.jsonl' if flat else day_path(day, sid))
        write(home, rel, rollout(sid, day, totals, parent), day, form)
        cases.append({'case': name, 'form': form, 'daysAgo': days_ago, 'root': 'archived_sessions' if flat else 'sessions'})

    add('plain rollout', 1, 3, 'plain', [100, 330])
    add('archive only (sessions)', 2, 8, 'archive', [100, 330])
    add('archive only (archived_sessions)', 3, 9, 'archive', [100, 330], flat=True)
    add('plain and archive both present', 4, 12, 'both', [100, 330])
    add('fork parent, archived 60 days ago', 5, 60, 'archive', [1000])
    add('fork child in window', 6, 14, 'plain', [1000, 1020], parent=uid(5))
    if include_corrupt:
        add('corrupt archive', 7, 16, 'corrupt', [100, 330])
    return cases


def decompressed_copy(src, dst):
    shutil.copytree(src, dst)
    for archive in dst.rglob('*.jsonl.zst'):
        plain = Path(str(archive)[:-4])
        if not plain.exists():
            # The corrupt archive cannot be decompressed, so the reference simply omits it.
            if subprocess.run(['zstd', '-q', '-d', str(archive), '-o', str(plain)], capture_output=True).returncode != 0:
                plain.unlink(missing_ok=True)
            else:
                stat = archive.stat()
                os.utime(plain, (stat.st_atime, stat.st_mtime))
        archive.unlink()


def run(cli, codex_home, home, passes=8):
    env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home), CODEX_HOME=str(codex_home))
    previous, same, summary = None, 0, None
    for _ in range(passes):
        out = subprocess.run([str(cli), 'cost', '--provider', 'codex', '--days', '30', '--refresh', '--format', 'json'],
                             env=env, capture_output=True, text=True, check=True).stdout
        entry = json.loads(out)
        entry = entry[0] if isinstance(entry, list) else entry
        daily = {d['date']: d.get('totalTokens') for d in entry.get('daily', [])}
        summary = {'totalTokens': (entry.get('totals') or {}).get('totalTokens'), 'days': len(daily), 'daily': daily,
                   'historyCoverageIsEstablished': entry.get('historyCoverageIsEstablished')}
        same = same + 1 if summary == previous else 0
        previous = summary
        if same >= 2:
            break
    return summary


def store_snapshot(home):
    db = home / 'Library/Caches/CodexBar/cost-usage/cost-usage.sqlite'
    con = sqlite3.connect(db)
    try:
        meta_rows = dict(con.execute('select key, value from meta'))
        rows = {Path(path).name: (updated, complete) for path, updated, complete
                in con.execute('select path, updated_at_ms, scan_complete from files')}
    finally:
        con.close()
    return {'inode': db.stat().st_ino, 'parserHash': meta_rows.get('parser_hash'), 'files': rows}


def mirror_permissions(home):
    """Modes of everything the head CLI wrote under the archive mirror, created under umask 022."""
    container = home / 'Library/Caches/CodexBar/cost-usage/codex-archived-rollouts'
    entries = [container, *sorted(container.rglob('*'))]
    modes = {}
    for entry in entries:
        kind = ('directory' if entry.is_dir() else 'decoded transcript' if entry.name.endswith('.jsonl')
                else 'failure ledger' if entry.name == '.failed-archives.json' else 'other')
        modes.setdefault(kind, set()).add(oct(entry.stat().st_mode & 0o777))
    return {
        'umask': '0o22',
        'modesByKind': {kind: sorted(values) for kind, values in sorted(modes.items())},
        'entriesAccessibleToOtherUsers': sum(1 for entry in entries if entry.stat().st_mode & 0o077),
        'entries': len(entries),
    }


def upgrade(base, head, codex_home, home):
    """A cache written by `base` is adopted in place by this branch."""
    run(base, codex_home, home, passes=3)
    before = store_snapshot(home)
    after_report = run(head, codex_home, home)
    after = store_snapshot(home)
    return {
        'parserHashBefore': before['parserHash'], 'parserHashAfter': after['parserHash'],
        'sameDatabaseInode': before['inode'] == after['inode'],
        'plainRowsRetainedUnchanged': {name: before['files'][name] == after['files'].get(name)
                                       for name in sorted(before['files'])},
        'report': after_report,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--base', type=Path)
    parser.add_argument('--upgrade-base', action='append', default=[], metavar='VERSION=CLI')
    parser.add_argument('--head', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    if not args.base and not args.upgrade_base:
        parser.error('pass --base, --upgrade-base, or both')
    # The default macOS umask; without explicit modes, new files would be 0644 and directories 0755.
    os.umask(0o022)
    with tempfile.TemporaryDirectory() as scratch:
        scratch = Path(scratch)
        fixture, clean = scratch / 'codex-home', scratch / 'codex-home-no-corrupt'
        cases = build_fixture(fixture)
        build_fixture(clean, include_corrupt=False)
        existing = args.out / 'proof.json'
        result = json.loads(existing.read_text()) if not args.base and existing.exists() else {}
        for spec in args.upgrade_base:
            version, cli = spec.split('=', 1)
            result[f'upgrade from {version} cache'] = upgrade(Path(cli), args.head, clean, scratch / f'u-{version}')
        if not args.base:
            args.out.mkdir(parents=True, exist_ok=True)
            existing.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
            print(json.dumps(result, indent=2, sort_keys=True))
            return
        reference = scratch / 'codex-home-decompressed'
        decompressed_copy(fixture, reference)

        result.update({'fixture': cases, 'window': '--days 30', 'scenarios': {
            'base 0.75.0, fixture': run(args.base, fixture, scratch / 'h1'),
            'head, fixture': run(args.head, fixture, scratch / 'h2'),
            'base 0.75.0, every archive decompressed in place (reference)': run(args.base, reference, scratch / 'h3'),
            'head, fixture without the corrupt archive': run(args.head, clean, scratch / 'h4'),
        }})
        result['head mirror permissions (fixture run)'] = mirror_permissions(scratch / 'h2')

        result['upgrade from 0.75.0 cache'] = upgrade(args.base, args.head, clean, scratch / 'h5')
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / 'proof.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
