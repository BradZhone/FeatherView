#!/bin/bash
# Copies build/FeatherView.app into /Applications (or ~/Applications if not writable) and registers
# it with Launch Services so it shows up in Launchpad / Spotlight / "Open With".
set -euo pipefail
cd "$(dirname "$0")/.."
NAME=FeatherView
BID=local.feather.editor
SRC=build/$NAME.app
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -d "$SRC" ] || { echo "run 'make' first"; exit 1; }

if [ -w /Applications ]; then DEST_DIR=/Applications; else DEST_DIR="$HOME/Applications"; mkdir -p "$DEST_DIR"; fi
DEST="$DEST_DIR/$NAME.app"
bundle_id() { /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$1/Contents/Info.plist" 2>/dev/null || true; }

# A running copy keeps its already-loaded binary; the new version is used from the next launch.
RUNNING=0
pgrep -xq "$NAME" && RUNNING=1
pgrep -xq Feather && RUNNING=1
if [ -e "$DEST" ]; then
    id=$(bundle_id "$DEST")
    [ "$id" = "$BID" ] || { echo "$DEST exists and was not built from this project (bundle id: ${id:-unknown}); nothing was changed."; exit 1; }
    rm -rf "$DEST"
fi
ditto "$SRC" "$DEST"
"$LSREGISTER" -f "$DEST"
echo "Installed to $DEST"

# Before the rename the app was Feather.app with the same bundle id: two copies would compete in
# Launch Services, so the old one goes to the Trash (recoverable; settings and sessions are kept).
OLD="$DEST_DIR/Feather.app"
if [ -d "$OLD" ] && [ "$(bundle_id "$OLD")" = "$BID" ]; then
    "$LSREGISTER" -u "$OLD" >/dev/null 2>&1 || true
    TRASHED="$HOME/.Trash/Feather $(date +%Y%m%d-%H%M%S).app"
    mv "$OLD" "$TRASHED"
    echo "Moved the old Feather.app to the Trash ($TRASHED); settings and sessions are kept."
fi
[ "$RUNNING" = 1 ] && echo "An older version is running: quit it (⌘Q) and open $NAME to use the new version."
exit 0
