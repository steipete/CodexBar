import argparse,ctypes,datetime,json,os,pathlib,re,subprocess,tempfile,time
parser=argparse.ArgumentParser()
parser.add_argument("--base", required=True)
parser.add_argument("--head", required=True)
parser.add_argument("--output", required=True)
args=parser.parse_args()
out=pathlib.Path(args.output);out.mkdir(parents=True,exist_ok=True)
root=pathlib.Path(tempfile.mkdtemp(prefix='codexbar-dashboard-proof-'))
cli=root/'fixture-cli'
cli.write_text('''#!/usr/bin/python3
import datetime,json,sys
if sys.argv[1]=='config': print(json.dumps([{'provider':'codex','displayName':'Codex'}]))
elif sys.argv[1]=='cost': print(json.dumps([{'provider':'codex','historyCoverageIsEstablished':True,'provenance':'listPriceEstimate','last30DaysCostUSD':3063.54,'last30DaysTokens':2992687053,'totals':{'inputTokens':2979214406,'outputTokens':13472647,'cacheReadTokens':2889979776},'daily':[{'date':datetime.date.today().isoformat(),'totalCost':88.44}]}]))
else: print(json.dumps([{'provider':'codex','usage':{'identity':{'loginMethod':'prolite'},'primary':{'usedPercent':57,'windowMinutes':10080,'resetsAt':'2030-01-01T00:00:00Z'}}}]))
''');cli.chmod(0o755)
env=dict(os.environ,DISPLAY=':193',QT_QPA_PLATFORM='xcb',QT_QUICK_BACKEND='software',PATH='/usr/bin:/bin')
env.pop("PYTHONHOME", None); env.pop("PYTHONPATH", None); env.pop("SESSION_MANAGER", None)
xvfb=subprocess.Popen(['/usr/bin/Xvfb',':193','-screen','0','1280x900x24','-nolisten','tcp'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
time.sleep(.5)
x=ctypes.CDLL('libX11.so.6');x.XOpenDisplay.argtypes=[ctypes.c_char_p];x.XOpenDisplay.restype=ctypes.c_void_p;x.XResizeWindow.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.c_uint,ctypes.c_uint];x.XFlush.argtypes=[ctypes.c_void_p];x.XCloseDisplay.argtypes=[ctypes.c_void_p]
display=x.XOpenDisplay(b':193');assert display
try:
 for label,binary in [('before',str(pathlib.Path(args.base).resolve())),('after',str(pathlib.Path(args.head).resolve()))]:
  home=root/label;home.mkdir();runtime=home/'runtime';runtime.mkdir(mode=0o700)
  e=dict(env,HOME=str(home),XDG_CONFIG_HOME=str(home/'config'),XDG_DATA_HOME=str(home/'data'),XDG_STATE_HOME=str(home/'state'),XDG_RUNTIME_DIR=str(runtime))
  log=(home/'app.log').open('w+')
  app=subprocess.Popen([binary,'--usage','--no-tray','--cli',str(cli)],env=e,stdout=log,stderr=log)
  def client(*args): return subprocess.run([binary,*args],env=e,capture_output=True,text=True,check=True).stdout
  try:
   for _ in range(50):
    try:
     snap=json.loads(client('--snapshot'))
     if snap.get('entries') and not snap.get('busy'):break
    except Exception:pass
    time.sleep(.1)
   else:raise RuntimeError('startup failed')
   tree=subprocess.check_output(['/usr/bin/xwininfo','-root','-tree'],env=e,text=True)
   match=re.search(r'(0x[0-9a-f]+) "Usage & Spend[^\n]*',tree);assert match,tree
   wid=int(match[1],16)
   for size,width in [('wide',820),('narrow',480)]:
    x.XResizeWindow(display,wid,width,700);x.XFlush(display);time.sleep(.3)
    subprocess.run(['/usr/bin/import','-window',hex(wid),str(out/f'{label}-usage-{size}.png')],env=e,check=True)
   client('--spending')
   for _ in range(50):
    snap=json.loads(client('--snapshot'))
    if snap.get('costProviders') and not snap.get('costBusy'):break
    time.sleep(.1)
   x.XResizeWindow(display,wid,820,700);x.XFlush(display);time.sleep(.3)
   subprocess.run(['/usr/bin/import','-window',hex(wid),str(out/f'{label}-spending.png')],env=e,check=True)
  finally:
   try:client('--quit');app.wait(timeout=5)
   except Exception:app.kill();app.wait()
   log.close()
finally:x.XCloseDisplay(display);xvfb.terminate();xvfb.wait()
print(out)
