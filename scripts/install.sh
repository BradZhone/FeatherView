#!/bin/bash
# Copies build/Feather.app into /Applications (or ~/Applications if not writable)
# and registers it with Launch Services so it shows up in Launchpad / Spotlight.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=build/Feather.app
[ -d "$SRC" ] || { echo "run 'make' first"; exit 1; }

if [ -w /Applications ]; then DEST_DIR=/Applications; else DEST_DIR="$HOME/Applications"; mkdir -p "$DEST_DIR"; fi
DEST="$DEST_DIR/Feather.app"

# A running copy keeps its already-loaded binary; the new version is used from the next launch.
RUNNING=0
pgrep -xq Feather && RUNNING=1
if [ -e "$DEST" ]; then
    id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$DEST/Contents/Info.plist" 2>/dev/null || true)
    if [ "$id" != "local.feather.editor" ]; then
        echo "$DEST 已存在且不是本项目构建的应用（bundle id: ${id:-未知}），未做改动。"; exit 1
    fi
    rm -rf "$DEST"
fi
ditto "$SRC" "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
echo "已安装到 $DEST"
[ "$RUNNING" = 1 ] && echo "Feather 正在运行：按 ⌘Q 退出后重新打开即可使用新版本。"
exit 0
