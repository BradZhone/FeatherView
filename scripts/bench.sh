#!/bin/bash
# Compares memory / CPU / process count of FeatherView, VS Code and Zed (and Chrome for an HTML page)
# opening the same workspace. Every app runs from a throwaway profile in a temp folder, so your own
# settings, sessions and extensions are not touched; only processes started here are killed.
#
#   scripts/bench.sh [runs=3] [settle-seconds=20] > results.tsv
#
# Memory is phys_footprint (Activity Monitor's "Memory" column) summed over the app's process tree.
# WebKit / Quick Look XPC helpers are children of launchd, not the app: for FeatherView they are
# attributed by "appeared after launch" (close Safari and other WebKit apps for a clean number).
set -u
cd "$(dirname "$0")/.."
[ -z "${CAFFEINATED:-}" ] && exec env CAFFEINATED=1 caffeinate -d -i "$0" "$@"     # keep the display on
RUNS=${1:-3}
SETTLE=${2:-20}
TMP=$(mktemp -d /tmp/fv-bench.XXXXXX)
FV_SRC=build/FeatherView.app
VSCODE="/Applications/Visual Studio Code.app/Contents/MacOS/Electron"
ZED_APP=${ZED_APP:-$(mdfind "kMDItemCFBundleIdentifier == 'dev.zed.Zed'" | head -1)}
CHROME=${CHROME_APP:-$(mdfind "kMDItemCFBundleIdentifier == 'com.google.Chrome'" | head -1)}
BENCH_BID=local.feather.bench
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
ZED_CFG="$HOME/.config/zed/settings.json"            # only read by Zed if --user-data-dir were ignored; restored anyway

log() { echo "$@" >&2; }

cleanup() {
    [ -n "${FV_APP:-}" ] && "$LSREGISTER" -u "$FV_APP" >/dev/null 2>&1
    defaults delete "$BENCH_BID" >/dev/null 2>&1
    rm -rf "$HOME/Library/Saved Application State/$BENCH_BID.savedState" "$HOME/Library/Caches/$BENCH_BID" \
           "$HOME/Library/Application Support/Feather-$BENCH_BID" "$HOME/Library/WebKit/$BENCH_BID" \
           "$HOME/Library/HTTPStorages/$BENCH_BID"
    if [ -f "$TMP/zed-settings.bak" ] && ! cmp -s "$TMP/zed-settings.bak" "$ZED_CFG"; then
        cp "$TMP/zed-settings.bak" "$ZED_CFG"; log "restored $ZED_CFG"
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT
[ -f "$ZED_CFG" ] && cp "$ZED_CFG" "$TMP/zed-settings.bak"

# --- FeatherView copy with its own bundle id (own defaults domain, never the installed app's) ---
[ -d "$FV_SRC" ] || { log "run make first"; exit 1; }
FV_APP="$TMP/FeatherViewBench.app"
ditto "$FV_SRC" "$FV_APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BENCH_BID" "$FV_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleDocumentTypes" "$FV_APP/Contents/Info.plist"
codesign --force --sign - "$FV_APP" >/dev/null 2>&1
"$LSREGISTER" -u "$FV_APP" >/dev/null 2>&1

# --- workspace: this repository plus typical files of a working day ---
# Each launch gets its own APFS clone at a new path, so no editor restores the previous run's tabs.
MASTER="$TMP/master"
rsync -a --exclude build --exclude dist ./ "$MASTER/"
python3 - "$MASTER" <<'EOF'
import sys, os, json, random
ws = sys.argv[1]; random.seed(1)
os.makedirs(f"{ws}/notes", exist_ok=True)
with open(f"{ws}/notes/design.md", "w") as f:
    for i in range(60):
        f.write(f"## 第 {i} 节\n\n这是一段说明文字，包含 **加粗**、`code` 和 [链接](https://example.com)。\n\n- 要点一\n- 要点二\n\n```python\ndef f(x):\n    return x * {i}\n```\n\n")
with open(f"{ws}/notes/data.csv", "w") as f:
    f.write("id,name,city,amount,date\n")
    for i in range(20000): f.write(f"{i},user{i},{random.choice(['北京','上海','深圳','杭州'])},{random.random()*1000:.2f},2026-{1+i%12:02d}-{1+i%28:02d}\n")
with open(f"{ws}/notes/config.json", "w") as f:
    json.dump({"service": {"name": "demo", "replicas": 3, "env": {f"KEY_{i}": f"value_{i}" for i in range(200)}},
               "items": [{"id": i, "tags": ["a", "b"], "enabled": i % 2 == 0} for i in range(500)]}, f, indent=2, ensure_ascii=False)
rows = "".join(f"<tr><td>{i}</td><td>模块 {i}</td><td>{random.randint(50,99)}%</td><td><div class='bar' style='width:{random.randint(10,100)}%'></div></td></tr>" for i in range(80))
with open(f"{ws}/notes/report.html", "w") as f:
    f.write(f"""<!doctype html><html lang="zh"><head><meta charset="utf-8"><title>AI 生成的分析报告</title>
<style>body{{font:15px -apple-system,sans-serif;max-width:960px;margin:40px auto;padding:0 20px;color:#222}}
h1{{font-size:28px}}.card{{display:inline-block;padding:16px 24px;margin:8px;border-radius:12px;background:#f2f5ff}}
table{{border-collapse:collapse;width:100%}}td{{border-bottom:1px solid #eee;padding:6px}}.bar{{height:8px;background:#4c7cf3;border-radius:4px}}
@media (prefers-color-scheme:dark){{body{{background:#1e1e1e;color:#ddd}}.card{{background:#2a2f3a}}td{{border-color:#333}}}}</style></head>
<body><h1>季度分析报告</h1><p>由 AI 根据日志与指标生成。</p>
<div class="card"><b>12,480</b><br>请求/分</div><div class="card"><b>99.95%</b><br>可用性</div><div class="card"><b>182 ms</b><br>P95 延迟</div>
<canvas id="c" width="900" height="220"></canvas><table>{rows}</table>
<script>const c=document.getElementById('c').getContext('2d');c.strokeStyle='#4c7cf3';c.lineWidth=2;c.beginPath();
for(let i=0;i<90;i++){{const y=110+60*Math.sin(i/7)+20*Math.cos(i/3);i?c.lineTo(i*10,y):c.moveTo(0,y)}}c.stroke();</script></body></html>""")
with open(f"{ws}/notes/server.log", "w") as f:
    line = 0
    while f.tell() < 50 * 1024 * 1024:
        f.write(f"2026-11-06T10:{line//60000%60:02d}:{line//1000%60:02d}.{line%1000:03d}Z INFO  [worker-{line%16}] request id={line:08x} path=/api/v1/items/{line%977} status=200 dur={line%300}ms\n")
        line += 1
EOF
SEQ=0
fresh_workspace() { SEQ=$((SEQ + 1)); WS="$TMP/ws$SEQ/workspace"; mkdir -p "$TMP/ws$SEQ"; cp -cR "$MASTER" "$WS"; }

# VS Code: defaults, minus telemetry / update checks / the welcome page (all favour VS Code slightly)
mkdir -p "$TMP/vscode/data/User" "$TMP/vscode/ext"
cat > "$TMP/vscode/data/User/settings.json" <<'EOF'
{ "telemetry.telemetryLevel": "off", "update.mode": "none", "workbench.startupEditor": "none",
  "extensions.autoCheckUpdates": false, "extensions.autoUpdate": false, "security.workspace.trust.enabled": false }
EOF

# --- process accounting ---
descendants() {   # pid → pid and all of its descendants
    ps -axo pid=,ppid= | awk -v root="$1" '{ kids[$2] = kids[$2] " " $1 }
        END { q[1] = root; n = 1; for (i = 1; i <= n; i++) { print q[i]; split(kids[q[i]], k, " "); for (j in k) if (k[j] != "") q[++n] = k[j] } }'
}
xpc_pids() { pgrep -f "com.apple.WebKit\.|QuickLookUIService|com.apple.quicklook" | sort; }
footprint_mb() {
    footprint -p "$1" 2>/dev/null | sed -n 's/.*Footprint: \([0-9.]*\) \([KMG]*B\).*/\1 \2/p' | head -1 |
        awk '{ v = $1; if ($2 == "KB") v /= 1024; else if ($2 == "GB") v *= 1024; printf "%.1f", v }'
}
cpu_seconds() {   # summed cputime of the given pids
    [ -n "$1" ] || { echo 0; return; }
    ps -o time= -p "$1" 2>/dev/null | awk '{ n = split($1, p, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + p[i]; t += s } END { printf "%.1f", t }'
}

launch() {   # app scenario → prints root pid
    local app=$1 sc=$2 files=()
    case $sc in idle) files=();;
        mixed) files=("$WS/src/Editor/TextEditorView.m" "$WS/notes/design.md" "$WS/notes/config.json" "$WS/notes/data.csv");; biglog) files=("$WS/notes/server.log");; html) files=("$WS/notes/report.html");; esac
    case $app in
    FeatherView)
        local args=("$WS"); for f in ${files[@]+"${files[@]}"}; do args+=(--open "$f"); done
        "$FV_APP/Contents/MacOS/FeatherView" "${args[@]}" >/dev/null 2>&1 & echo $! ;;
    "VS Code")
        "$VSCODE" --user-data-dir "$TMP/vscode/data" --extensions-dir "$TMP/vscode/ext" --new-window \
            --skip-release-notes --skip-welcome --disable-workspace-trust "$WS" ${files[@]+"${files[@]}"} >/dev/null 2>&1 & echo $! ;;
    Zed)
        # the zed binary itself: the `cli` wrapper hands off to a running Zed and ignores --user-data-dir
        "$ZED_APP/Contents/MacOS/zed" --user-data-dir "$TMP/zed" "$WS" ${files[@]+"${files[@]}"} >/dev/null 2>&1 & echo $! ;;
    Chrome)
        "$CHROME/Contents/MacOS/Google Chrome" --user-data-dir="$TMP/chrome" --no-first-run --no-default-browser-check \
            --disable-sync --new-window "file://${files[0]}" >/dev/null 2>&1 & echo $! ;;
    esac
}

stop() {   # root pid + extra pids
    local all; all=$(descendants "$1"; echo "$2")
    kill $all 2>/dev/null; sleep 2; kill -9 $all 2>/dev/null; sleep 1
}

measure() {   # app scenario run → TSV row
    local before after extra root pids mem=0 n=0 cpu
    fresh_workspace
    before=$(xpc_pids)
    root=$(launch "$1" "$2")
    [ -n "$root" ] || { log "could not start $1"; return; }
    sleep "$SETTLE"
    after=$(xpc_pids)
    extra=""; [ "$1" = FeatherView ] && extra=$(comm -13 <(echo "$before") <(echo "$after") | tr '\n' ' ')
    pids=$( (descendants "$root"; for p in $extra; do echo "$p"; done) | sort -un)
    for p in $pids; do m=$(footprint_mb "$p"); [ -n "$m" ] && { mem=$(echo "$mem + $m" | bc); n=$((n + 1)); }; done
    cpu=$(cpu_seconds "$(echo $pids | tr ' ' ',')")
    printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$1" "$2" "$3" "$mem" "$n" "$cpu"
    stop "$root" "$extra"
    rm -rf "$(dirname "$WS")"
}

APPS=(FeatherView "VS Code" Zed); [ -n "${ONLY:-}" ] && APPS=("$ONLY")   # ONLY=Zed reruns one editor
log "workspace: $(find "$MASTER" -type f | wc -l | tr -d ' ') files, $(du -sh "$MASTER" | cut -f1)"
for app in "${APPS[@]}"; do          # first launch: profiles, caches, language servers get set up
    log "warm-up $app"; fresh_workspace; r=$(launch "$app" mixed); sleep $((SETTLE + 15)); stop "$r" ""
done
[ -z "${ONLY:-}" ] && { log "warm-up Chrome"; fresh_workspace; r=$(launch Chrome html); sleep "$SETTLE"; stop "$r" ""; }

printf "app\tscenario\trun\tmemory_mb\tprocesses\tcpu_s\n"
for run in $(seq 1 "$RUNS"); do
    for sc in idle mixed biglog; do for app in "${APPS[@]}"; do log "$app $sc #$run"; measure "$app" "$sc" "$run"; done; done
    [ -z "${ONLY:-}" ] && for app in FeatherView Chrome; do log "$app html #$run"; measure "$app" html "$run"; done
done
