#!/usr/bin/env bash
# Quits Helios, waits until it has fully exited, then reopens it
# (the installed /Applications copy if there is one, else ./build.noindex).
# (Running `open` while the old copy is still quitting silently does nothing.)
set -euo pipefail
cd "$(dirname "$0")/.."

osascript -e 'tell application id "local.helios" to quit' >/dev/null 2>&1 || true
for _ in $(seq 1 50); do
    pgrep -f "Helios.app/Contents/MacOS/Helios" >/dev/null || break
    sleep 0.1
done
if [[ -d /Applications/Helios.app ]]; then
    open /Applications/Helios.app
else
    open build.noindex/Helios.app
fi
