#!/bin/bash
# Brings the installed Boxtop to the front and prints its CPU use (from CPU-time deltas) with the full
# layout and with each pane maximized alone. Runs on the Mac being measured; needs Accessibility
# access for System Events (it drives View > Maximize Pane).
#   scripts/pane-cost.sh [seconds per reading]
#   ssh user@host 'bash -s' -- 20 < scripts/pane-cost.sh
set -euo pipefail
SECS=${1:-20}
pct() {  # CPU % of one core used by pid $1 over $2 seconds
  local a b; a=$(ps -o time= -p "$1"); sleep "$2"; b=$(ps -o time= -p "$1")
  awk -v a="$a" -v b="$b" -v t="$2" 'function s(x,  n, p, i, v) { n = split(x, p, ":"); v = 0; for (i = 1; i <= n; i++) v = v * 60 + p[i]; return v }
    BEGIN { printf "%.1f\n", (s(b) - s(a)) / t * 100 }'
}
menu() {  # menu "View" "Maximize Pane" "CPU"  (path into Boxtop's menu bar)
  osascript -e 'on run argv
    tell application "Boxtop" to activate
    tell application "System Events" to tell process "Boxtop"
      if (count of argv) is 3 then
        click menu item (item 3 of argv) of menu 1 of menu item (item 2 of argv) of menu 1 of menu bar item (item 1 of argv) of menu bar 1
      else
        click menu item (item 2 of argv) of menu 1 of menu bar item (item 1 of argv) of menu bar 1
      end if
    end tell
  end run' "$@" >/dev/null
}
open -a /Applications/Boxtop.app; osascript -e 'tell application "Boxtop" to activate'; sleep 4
P=$(pgrep -f /Applications/Boxtop.app/Contents/MacOS/Boxtop)
{
  echo "version $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' /Applications/Boxtop.app/Contents/Info.plist), ${SECS}s each"
  sleep 4; echo "all panes: $(pct "$P" "$SECS")"
  for pane in CPU Memory Network Processes GPU Disks; do
    menu View "Maximize Pane" "$pane"; sleep 4
    echo "only $pane: $(pct "$P" "$SECS")"
    menu View "Maximize Pane" "Restore Layout"
  done
  sleep 3; echo "all panes again: $(pct "$P" "$SECS")"
}
