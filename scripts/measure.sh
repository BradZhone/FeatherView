#!/bin/bash
# Launches FeatherView with different files and reports phys_footprint (what Activity Monitor shows).
# Usage: scripts/measure.sh [root-dir]
set -u
cd "$(dirname "$0")/.."
BIN=build/FeatherView.app/Contents/MacOS/FeatherView
ROOT=${1:-$PWD}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# test inputs
cp src/TextEditorView.m "$TMP/small.m"
for i in $(seq 1 40); do cat /usr/share/dict/words; done > "$TMP/big.txt"          # ~100 MB
head -c 2000000 /dev/urandom > "$TMP/random.bin"
IMG="/System/Library/Desktop Pictures/iMac Blue.heic"
PDF=$(find /System/Library /Library -name "*.pdf" -size +200k 2>/dev/null | head -1)

sample() {   # label, file
    "$BIN" "$ROOT" ${2:+--open "$2"} >/dev/null 2>&1 &
    local pid=$!
    sleep 4
    local out fp surf
    out=$(footprint -p $pid 2>/dev/null)
    fp=$(echo "$out" | sed -n 's/.*Footprint: \([0-9.]* [KMG]*B\).*/\1/p' | head -1)
    surf=$(echo "$out" | awk '$NF == "IOSurface" {print $1, $2}' | head -1)
    # IOSurface = window backing store; absent means the window was not composited (other Space, occluded…)
    printf "%-26s %8s   window surface: %s\n" "$1" "${fp:-n/a}" "${surf:-none (not on screen)}"
    kill $pid 2>/dev/null; wait $pid 2>/dev/null
}

echo "root: $ROOT"
sample "empty (tree only)"
sample "small source file" "$TMP/small.m"
sample "100 MB text file" "$TMP/big.txt"
sample "2 MB binary (hex)" "$TMP/random.bin"
sample "6016x6016 HEIC image" "$IMG"
[ -n "$PDF" ] && sample "PDF (Quick Look)" "$PDF"
