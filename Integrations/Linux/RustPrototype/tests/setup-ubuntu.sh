#!/usr/bin/env bash
# Dependencies for native Ubuntu 24.04 GitHub runners and disposable Crabbox VMs.
set -euo pipefail
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  build-essential pkg-config curl ca-certificates git binutils \
  qt6-base-dev qt6-declarative-dev qt6-wayland libqt6svg6 \
  qml6-module-qtquick qml6-module-qtquick-controls qml6-module-qtquick-layouts \
  qml6-module-qtquick-window qml6-module-qtquick-templates qml6-module-qtqml-workerscript \
  python3 file dbus dbus-x11 xvfb xauth xfce4-panel xfconf weston scrot fonts-dejavu-core
