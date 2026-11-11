"""Capture the built Linux desktop with fixture data on a private X11 display.

Requires Qt 6.4+, Xvfb, xfwm4, dbus-run-session, xwininfo, xprop,
xsetroot, ImageMagick import, libX11 and libXtst. Never connects to accounts.
"""
import argparse
import ctypes
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time
from upgrade import run_upgrade


def wait_for(predicate, description):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.1)
    raise AssertionError(description)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--display', default=':194')
    parser.add_argument('--screen-width', type=int, default=1024)
    parser.add_argument('--legacy-binary')
    args = parser.parse_args()
    binary = str(Path(args.binary).resolve())
    out = Path(args.output).resolve()
    out.mkdir(parents=True, exist_ok=True)
    display_number = int(args.display.removeprefix(':'))
    assert not Path(f'/tmp/.X11-unix/X{display_number}').exists(), 'Choose a free display'
    evidence = {
        'binarySHA256': hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
        'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
        'qtVersion': subprocess.check_output(['/usr/bin/qmake6', '-query', 'QT_VERSION'], text=True).strip(),
        'platform': 'Private Xvfb display, xcb, xfwm4 without compositing, software rendering',
        'dataSource': 'Fake CLI in private HOME/XDG directories; no account credentials',
        'scenarios': [],
    }
    subprocess.run(['git', 'diff', '--exit-code', 'HEAD', '--', 'Integrations/Linux'], check=True)
    with tempfile.TemporaryDirectory(prefix='codexbar-floating-proof-') as directory:
        root = Path(directory)
        env = dict(os.environ, DISPLAY=args.display, HOME=str(root),
                   XDG_CONFIG_HOME=str(root / 'wm-config'), XDG_RUNTIME_DIR=str(root / 'wm-runtime'),
                   XDG_CACHE_HOME=str(root / 'wm-cache'), XDG_DATA_HOME=str(root / 'wm-data'),
                   XDG_STATE_HOME=str(root / 'wm-state'), QT_QPA_PLATFORM='xcb',
                   QT_QUICK_BACKEND='software', GDK_BACKEND='x11', GIO_USE_VFS='local', PATH='/usr/bin:/bin')
        for key in ['PYTHONHOME', 'PYTHONPATH', 'SESSION_MANAGER', 'DBUS_SESSION_BUS_ADDRESS']:
            env.pop(key, None)
        (root / 'wm-runtime').mkdir(mode=0o700)
        xlog = (root / 'xvfb.log').open('w+')
        wlog = (root / 'wm.log').open('w+')
        xvfb = subprocess.Popen(['/usr/bin/Xvfb', args.display, '-screen', '0', f'{args.screen_width}x900x24',
                                 '-nolisten', 'tcp'], env=env, stdout=xlog, stderr=xlog)
        wm = None
        x = ctypes.CDLL('libX11.so.6')
        x.XOpenDisplay.argtypes = [ctypes.c_char_p]
        x.XOpenDisplay.restype = ctypes.c_void_p
        x.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
        x.XDefaultRootWindow.restype = ctypes.c_ulong
        x.XFlush.argtypes = [ctypes.c_void_p]
        x.XCloseDisplay.argtypes = [ctypes.c_void_p]
        x.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        x.XKeysymToKeycode.restype = ctypes.c_uint
        xt = ctypes.CDLL('libXtst.so.6')
        xt.XTestFakeMotionEvent.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_ulong]
        xt.XTestFakeButtonEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
        xt.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
        display = None
        try:
            wait_for(lambda: Path(f'/tmp/.X11-unix/X{display_number}').exists(), 'Xvfb startup')
            display = x.XOpenDisplay(args.display.encode())
            assert display
            wm = subprocess.Popen(['/usr/bin/dbus-run-session', '--', '/usr/bin/xfwm4',
                                   '--compositor=off', '--sm-client-disable'], env=env,
                                  stdout=wlog, stderr=wlog, start_new_session=True)
            def wm_ready():
                return 'window id #' in subprocess.check_output(
                    ['/usr/bin/xprop', '-root', '_NET_SUPPORTING_WM_CHECK'], env=env, text=True)
            wait_for(wm_ready, 'xfwm4 startup')
            subprocess.run(['/usr/bin/xsetroot', '-solid', '#26313d'], env=env, check=True)

            def move(px, py):
                xt.XTestFakeMotionEvent(display, -1, px, py, 0)
                x.XFlush(display)
                time.sleep(0.1)

            def click(px, py, button=1):
                move(px, py)
                xt.XTestFakeButtonEvent(display, button, 1, 0)
                xt.XTestFakeButtonEvent(display, button, 0, 0)
                x.XFlush(display)

            def escape():
                key = x.XKeysymToKeycode(display, 0xff1b)
                xt.XTestFakeKeyEvent(display, key, 1, 0)
                xt.XTestFakeKeyEvent(display, key, 0, 0)
                x.XFlush(display)

            for scenario in ['weekly', 'dual', 'narrow']:
                home = root / scenario
                home.mkdir()
                (home / 'runtime').mkdir(mode=0o700)
                runtime_env = dict(env, HOME=str(home), XDG_CONFIG_HOME=str(home / 'config'),
                                   XDG_DATA_HOME=str(home / 'data'), XDG_STATE_HOME=str(home / 'state'),
                                   XDG_CACHE_HOME=str(home / 'cache'), XDG_RUNTIME_DIR=str(home / 'runtime'))
                today = datetime.datetime.now(datetime.timezone.utc)
                reset = lambda delta: (today + delta).isoformat().replace('+00:00', 'Z')
                weekly = {'usedPercent': 58 if scenario == 'weekly' else 29,
                          'windowMinutes': 10080, 'resetsAt': reset(datetime.timedelta(days=4, hours=22))}
                usage = {'identity': {'loginMethod': 'Fixture plan'}}
                if scenario == 'weekly':
                    usage['primary'] = weekly
                else:
                    usage['primary'] = {'usedPercent': 97, 'windowMinutes': 300,
                                        'resetsAt': reset(datetime.timedelta(hours=2, minutes=58))}
                    usage['secondary'] = weekly
                payload = [{'provider': 'codex', 'usage': usage}]
                if scenario == 'narrow':
                    payload = [json.loads(json.dumps(payload[0])) for _ in range(3)]
                    for index, entry in enumerate(payload):
                        entry['usage']['primary']['usedPercent'] = [97, 50, 9][index]
                        entry['usage']['secondary']['usedPercent'] = [29, 39, 49][index]
                    config_dir = home / 'config/codexbar'
                    config_dir.mkdir(parents=True)
                    (config_dir / 'linux.json').write_text('{"allAccounts":true}')
                (home / 'usage.json').write_text(json.dumps(payload))
                cli = home / 'fixture-cli'
                cli.write_text('''#!/usr/bin/python3
import json,pathlib,sys
root=pathlib.Path(__file__).parent
with (root/'calls.jsonl').open('a') as log: log.write(json.dumps(sys.argv[1:])+'\\n')
if sys.argv[1]=='config': print(json.dumps([{'provider':'codex','displayName':'Codex'}]))
elif sys.argv[1]=='usage': print((root/'usage.json').read_text())
else: raise SystemExit('Unexpected fixture command')
''')
                cli.chmod(0o755)
                log = (home / 'app.log').open('w+')
                app = subprocess.Popen([binary, '--background', '--no-tray', '--cli', str(cli)],
                                       env=runtime_env, stdout=log, stderr=log)
                def client(*arguments):
                    result = subprocess.run([binary, *arguments], env=runtime_env,
                                            capture_output=True, text=True, timeout=10, check=True)
                    return json.loads(result.stdout) if result.stdout.strip() else {}
                def ready():
                    if app.poll() is not None:
                        log.flush(); log.seek(0)
                        raise RuntimeError(log.read())
                    try:
                        value = client('--snapshot')
                        return bool(value.get('entries')) and not value.get('busy')
                    except subprocess.CalledProcessError:
                        return False
                def calls():
                    return [json.loads(line) for line in (home / 'calls.jsonl').read_text().splitlines()]
                def preferences():
                    return json.loads((home / 'config/codexbar/linux.json').read_text())
                def tree():
                    return subprocess.check_output(['/usr/bin/xwininfo', '-root', '-tree'],
                                                   env=runtime_env, text=True)
                def gauge_id():
                    match = re.search(r'(0x[0-9a-f]+) "CodexBar[^\n"]*Floating Gauge[^\n"]*"', tree())
                    return match.group(1) if match else None
                def geometry(wid):
                    info = subprocess.check_output(['/usr/bin/xwininfo', '-id', wid], env=runtime_env, text=True)
                    def integer(name):
                        return int(re.search(name + r':\s+(-?\d+)', info).group(1))
                    return {'x': integer('Absolute upper-left X'), 'y': integer('Absolute upper-left Y'),
                            'width': integer('Width'), 'height': integer('Height'),
                            'overrideRedirect': 'Override Redirect State: yes' in info,
                            'viewable': 'Map State: IsViewable' in info}
                def capture(name, geom=None):
                    g = geom or geometry(gauge_id())
                    move(args.screen_width-24, 800)
                    time.sleep(0.25)
                    subprocess.run(['/usr/bin/import', '-window', 'root', '-crop',
                                    f"{g['width']+32}x{g['height']+32}+{max(0,g['x']-16)}+{max(0,g['y']-16)}",
                                    '+repage', str(out / name)], env=runtime_env, check=True)
                try:
                    wait_for(ready, 'fixture usage startup')
                    assert not gauge_id() or not geometry(gauge_id())['viewable'], 'Gauge should be opt-in'
                    before = calls()
                    client('--floating')
                    (out / (scenario + '-window-tree.log')).write_text(tree())
                    wait_for(lambda: gauge_id() and geometry(gauge_id())['viewable'], 'Show capsule')
                    wid = gauge_id()
                    g = geometry(wid)
                    assert g['height'] == 48
                    assert g['x'] >= 0 and g['x']+g['width'] <= args.screen_width
                    if scenario == 'narrow':
                        assert len(client('--snapshot')['entries']) == 3
                    capture(scenario + '-compact.png')
                    row = {'scenario': scenario, 'compactGeometry': g}
                    state = subprocess.check_output(['/usr/bin/xprop', '-id', wid, '_NET_WM_STATE'],
                                                    env=runtime_env, text=True).strip()
                    assert '_NET_WM_STATE_ABOVE' in state, state
                    row['topmostState'] = state
                    click(g['x'] + g['width']//2, g['y'] + 22)
                    wait_for(lambda: geometry(wid)['height'] == preferences()['floatingHeight'] and
                             geometry(wid)['width'] == preferences()['floatingWidth'], 'Click restores expanded size')
                    capture(scenario + '-expanded.png')
                    row['expandedGeometry'] = geometry(wid)
                    if scenario == 'dual':
                        g = geometry(wid)
                        start = (g['x'] + 45, g['y'] + 25)
                        move(*start)
                        xt.XTestFakeButtonEvent(display, 1, 1, 0); x.XFlush(display)
                        for delta in [20, 45, 80]: move(start[0]+delta, start[1]+delta//2)
                        xt.XTestFakeButtonEvent(display, 1, 0, 0); x.XFlush(display)
                        wait_for(lambda: geometry(wid)['x'] != g['x'], 'Header drag moves window')
                        row['draggedGeometry'] = geometry(wid)
                        g = geometry(wid)
                        start = (g['x']+g['width']-7, g['y']+g['height']-7)
                        move(*start)
                        xt.XTestFakeButtonEvent(display, 1, 1, 0); x.XFlush(display)
                        for delta in [20, 50, 80]: move(start[0]+delta, start[1]+delta//2)
                        xt.XTestFakeButtonEvent(display, 1, 0, 0); x.XFlush(display)
                        wait_for(lambda: geometry(wid)['width'] > g['width'], 'Grip resizes window')
                        row['resizedGeometry'] = geometry(wid)
                        # The UI collapse button flushes drag/resize geometry before changing mode.
                        g = geometry(wid)
                        click(g['x']+g['width']-50, g['y']+28)
                        wait_for(lambda: geometry(wid)['height'] == 48, 'Click collapses')
                        assert preferences()['floatingWidth'] == row['resizedGeometry']['width']
                        assert preferences()['floatingHeight'] == row['resizedGeometry']['height']
                        client('--configure', '{"quotaDisplay":"used"}')
                        capture('dual-used.png')
                        client('--configure', '{"quotaDisplay":"remaining"}')
                        g = geometry(wid)
                        click(g['x']+g['width']-30, g['y']+22, 3)
                        time.sleep(0.3)
                        popup = None
                        # Qt 6.4 QMenu can expose NORMAL rather than POPUP_MENU to EWMH.
                        # Identify the mapped, override-redirect native app popup instead.
                        for candidate in re.findall(r'(0x[0-9a-f]+) "CodexBar"[^\n]*codexbar-linux', tree()):
                            candidate_geom = geometry(candidate)
                            if candidate_geom['viewable'] and candidate_geom['overrideRedirect']:
                                popup = candidate_geom
                                break
                        assert popup and popup['height'] > 48, 'Native menu visible outside capsule bounds'
                        row['popupGeometry'] = popup
                        capture('native-menu.png', {'x': min(g['x'],popup['x']), 'y': min(g['y'],popup['y']),
                            'width': max(g['x']+g['width'],popup['x']+popup['width'])-min(g['x'],popup['x']),
                            'height': max(g['y']+g['height'],popup['y']+popup['height'])-min(g['y'],popup['y'])})
                        escape()
                    client('--configure', '{"floatingCompact":false}')
                    wait_for(lambda: geometry(wid)['height'] > 48, 'Expanded before restart')
                    assert calls() == before, 'Display interactions must not fetch usage or spending'
                    row['queriesDuringInteractions'] = 0
                    client('--quit'); app.wait(timeout=5)
                    app = subprocess.Popen([binary, '--background', '--no-tray', '--cli', str(cli)],
                                           env=runtime_env, stdout=log, stderr=log)
                    wait_for(ready, 'Restart fixture app')
                    wait_for(lambda: gauge_id() and geometry(gauge_id())['viewable'], 'Restart visible capsule')
                    row['restartGeometry'] = geometry(gauge_id())
                    assert row['restartGeometry']['height'] == 48, 'Restart should be compact'
                    if scenario == 'dual':
                        assert row['restartGeometry']['x'] == row['draggedGeometry']['x']
                        assert row['restartGeometry']['y'] == row['draggedGeometry']['y']
                    capture(scenario + '-restarted.png')
                    if scenario == 'dual':
                        g = row['restartGeometry']
                        click(g['x']+g['width']//2, g['y']+22)
                        wait_for(lambda: geometry(gauge_id())['width'] == row['resizedGeometry']['width'] and
                                 geometry(gauge_id())['height'] == row['resizedGeometry']['height'],
                                 'Expanded size survives restart')
                        row['restoredExpandedGeometry'] = geometry(gauge_id())
                        capture('dual-restored-expanded.png')
                    recorded = calls()
                    assert sum(command[0]=='usage' for command in recorded) == 2, recorded
                    assert not any(command[0]=='cost' for command in recorded), recorded
                    row['totalUsageQueriesIncludingRestart'] = 2
                    row['costQueries'] = 0
                    row['fixtureCalls'] = recorded
                    evidence['scenarios'].append(row)
                finally:
                    if app.poll() is None:
                        try: client('--quit'); app.wait(timeout=5)
                        except Exception: app.kill(); app.wait()
                    log.flush(); log.seek(0)
                    (out / (scenario + '-app.log')).write_text(log.read())
                    log.close()
            evidence['result'] = 'passed'
            (out / 'results.json').write_text(json.dumps(evidence, indent=2)+'\n')
            if args.legacy_binary:
                run_upgrade(args.legacy_binary, binary, env, out)
            print(json.dumps(evidence, indent=2))
        finally:
            if display: x.XCloseDisplay(display)
            if wm:
                os.killpg(wm.pid, signal.SIGTERM)
                wm.wait(timeout=5)
            xvfb.terminate(); xvfb.wait(timeout=5)
            xlog.close(); wlog.close()


if __name__ == '__main__':
    main()
