#!/usr/bin/env bash
# All desktop services and configuration live in a disposable private session.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ ${1:-} != --inside-session ]]; then
  exec dbus-run-session -- bash "$0" --inside-session
fi
session_dir=$(mktemp -d)
export XDG_RUNTIME_DIR="$session_dir/runtime"
export XDG_CONFIG_HOME="$session_dir/config"
export XDG_CACHE_HOME="$session_dir/cache"
export XDG_DATA_HOME="$session_dir/data"
mkdir -p "$XDG_RUNTIME_DIR" "$XDG_CONFIG_HOME/xfce4/xfconf/xfce-perchannel-xml"
chmod 700 "$XDG_RUNTIME_DIR"
evidence_dir=${PROTOTYPE_EVIDENCE_DIR:-$session_dir/evidence}
mkdir -p "$evidence_dir"
children=()
cleanup() {
  for child in "${children[@]}"; do kill "$child" 2>/dev/null || true; done
  for child in "${children[@]}"; do wait "$child" 2>/dev/null || true; done
  rm -rf -- "$session_dir"
}
trap cleanup EXIT
cat > "$XDG_CONFIG_HOME/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-panel" version="1.0">
  <property name="configver" type="int" value="2"/>
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=6;x=640;y=20"/>
      <property name="position-locked" type="bool" value="true"/>
      <property name="size" type="uint" value="40"/>
      <property name="length" type="uint" value="100"/>
      <property name="plugin-ids" type="array"><value type="int" value="1"/></property>
    </property>
  </property>
  <property name="plugins" type="empty"><property name="plugin-1" type="string" value="systray"/></property>
</channel>
XML
Xvfb -displayfd 3 -screen 0 1280x900x24 -nolisten tcp 3> "$session_dir/display" > "$evidence_dir/xvfb.log" 2>&1 &
children+=("$!")
for attempt in {1..100}; do [[ -s "$session_dir/display" ]] && break; sleep 0.1; done
[[ -s "$session_dir/display" ]]
export DISPLAY=":$(cat "$session_dir/display")"
GDK_BACKEND=x11 xfce4-panel --disable-wm-check > "$evidence_dir/panel.log" 2>&1 &
children+=("$!")
ready=false
for attempt in {1..100}; do
  if busctl --user get-property org.kde.StatusNotifierWatcher /StatusNotifierWatcher org.kde.StatusNotifierWatcher IsStatusNotifierHostRegistered 2>/dev/null | grep -q true; then ready=true; break; fi
  sleep 0.1
done
[[ "$ready" == true ]] || { cat "$evidence_dir/panel.log"; exit 1; }
PROTOTYPE_TEST_TRAY=1 PROTOTYPE_QPA=xcb python3 "$script_dir/smoke.py" 2>&1 | tee "$evidence_dir/x11.log"
weston --backend=headless-backend.so --renderer=pixman --socket=codexbar-test-wayland --idle-time=0 --width=1280 --height=900 \
  > "$evidence_dir/weston.log" 2>&1 &
children+=("$!")
for attempt in {1..100}; do [[ -S "$XDG_RUNTIME_DIR/codexbar-test-wayland" ]] && break; sleep 0.1; done
[[ -S "$XDG_RUNTIME_DIR/codexbar-test-wayland" ]] || { cat "$evidence_dir/weston.log"; exit 1; }
WAYLAND_DEBUG=client WAYLAND_DISPLAY=codexbar-test-wayland PROTOTYPE_TEST_TRAY=1 PROTOTYPE_QPA=wayland \
  python3 "$script_dir/smoke.py" 2>&1 | tee "$evidence_dir/wayland.log"
