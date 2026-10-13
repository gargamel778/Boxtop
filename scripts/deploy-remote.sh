#!/bin/bash
# Installs build/Boxtop.app on another Mac over SSH, prints its diagnostics and launches it.
#   scripts/deploy-remote.sh user@host
# Needs key-based SSH (ssh-copy-id user@host) and a user logged in on that Mac for the launch.
set -euo pipefail
cd "$(dirname "$0")/.."

HOST=${1:?usage: scripts/deploy-remote.sh user@host}
APP=build/Boxtop.app
[ -d "$APP" ] || scripts/build-app.sh

echo "==> Remote system"
ssh "$HOST" 'sw_vers -productVersion; uname -m; sysctl -n machdep.cpu.brand_string'

echo "==> Copying $APP to $HOST"
ssh "$HOST" 'pkill -x Boxtop 2>/dev/null || true; rm -rf /tmp/Boxtop.app'
tar -C build -cf - Boxtop.app | ssh "$HOST" 'tar -C /tmp -xf -'

echo "==> Installing"
ssh "$HOST" '
  set -e
  if [ -w /Applications ]; then DEST=/Applications; else DEST="$HOME/Applications"; mkdir -p "$DEST"; fi
  rm -rf "$DEST/Boxtop.app"
  ditto /tmp/Boxtop.app "$DEST/Boxtop.app"
  rm -rf /tmp/Boxtop.app
  codesign --verify --deep --strict "$DEST/Boxtop.app" && echo "installed to $DEST/Boxtop.app (signature ok)"
'

echo "==> Diagnostics"
ssh "$HOST" 'B=/Applications/Boxtop.app; [ -d "$B" ] || B="$HOME/Applications/Boxtop.app"; "$B/Contents/MacOS/Boxtop" --diagnose'

echo "==> Launching"
ssh "$HOST" 'B=/Applications/Boxtop.app; [ -d "$B" ] || B="$HOME/Applications/Boxtop.app"; open "$B" && sleep 4 && pgrep -fl "Boxtop.app/Contents/MacOS/Boxtop"'
