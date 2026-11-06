# Resource usage: FeatherView, VS Code and Zed

[简体中文](benchmark.zh-Hans.md)

This document compares the memory, CPU time and process count of FeatherView, Visual Studio Code and Zed when opening the same workspace and the same files. Viewing an HTML page is additionally compared with Google Chrome. The figures can be reproduced with [`scripts/bench.sh`](../scripts/bench.sh).

## Results

Memory is the median of three runs, with the range in parentheses. CPU is the cumulative CPU time consumed during the first 20 seconds after launch.

| Scenario | FeatherView 0.15.0 | VS Code 1.107.1 | Zed 1.26.2 |
|---|---|---|---|
| Workspace open, no files | **22 MB** (22–23) · 1 process · 0.1 s | 535 MB (513–561) · 7 processes · 3.7 s | 109 MB (106–126) · 2 processes · 0.7 s |
| Four files open: Objective-C source, Markdown, JSON, 20,000-row CSV | **67 MB** (66–67) · 1 · 0.3 s | 706 MB (704–768) · 7 · 5.3 s | 121 MB (121–138) · 2 · 0.9 s |
| 50 MB log file open | **41 MB** (41–43) · 1 · 0.1 s | 716 MB (715–717) · 7 · 5.0 s | 255 MB (236–256) · 2 · 1.2 s |

| Scenario | FeatherView 0.15.0 | Chrome 157 |
|---|---|---|
| AI-generated HTML report (styles, table, canvas script) | **92 MB** (75–98) · 4 processes · 0.4 s | 194 MB (192–194) · 7 processes · 0.9 s |

| Application size | FeatherView | VS Code | Zed | Chrome |
|---|---|---|---|---|
| `.app` bundle | 4 MB (universal, arm64 + x86_64) | 659 MB | 176 MB | 1.4 GB |

In these scenarios FeatherView used roughly 1/10 to 1/25 of the memory of VS Code and 1/2 to 1/6 of the memory of Zed. Viewing an HTML page took about half the memory of Chrome, while also providing the file tree and source editing in the same window.

Per-run data is available in [benchmark-results.tsv](benchmark-results.tsv).

## Interpretation

- **FeatherView does less.** It has no language servers, extensions, Git integration or terminal. VS Code's seven processes include the extension host, file watcher and terminal host; with commonly used extensions installed, its memory use would be considerably higher. The comparison answers the question "what does viewing and light editing cost?", not "which editor is better?".
- **Zed did not start a language server.** With a fresh profile, Zed did not launch a Node-based JSON language server during the measurement window; only the main process and its crash handler were running. In everyday use with language servers active, Zed's usage would be higher.
- **Large files show the largest difference.** FeatherView memory-maps files instead of copying them and lays out only the visible lines, so a 50 MB log adds about 20 MB over an empty workspace. Zed and VS Code read the whole file into their own buffers.
- **The four processes in the HTML scenario** are FeatherView itself plus WebKit's WebContent, GPU and Networking helpers. These exist only once an HTML file has been opened; Markdown, tables and JSON are rendered natively and do not start WebKit.
- **Window visibility affects the reading.** When a native window is frontmost and composited, its backing store counts towards memory (10–30 MB for a large Retina window). Each measured application was frontmost, so conditions are equivalent, but different default window sizes still account for differences of a few megabytes.

## Environment

- MacBook Pro, Apple M4, 16 GB memory, macOS 15.5, built-in Liquid Retina XDR display (3024 × 1964)
- VS Code 1.107.1, Zed 1.26.2 and Chrome 157.0.8103.38, all official releases
- Workspace: a copy of this repository (208 files, 53 MB) plus generated files: a 60-section Markdown document, a 20,000-row CSV, a 500-item JSON document, an AI-style HTML report and a 50 MB log

## Method

The script is [`scripts/bench.sh`](../scripts/bench.sh): `scripts/bench.sh 3 20 > results.tsv` runs three rounds with a 20-second settling time.

- **Memory** is `phys_footprint` as reported by `footprint`, which is the value in Activity Monitor's Memory column, summed over the application's process tree. RSS is not used because it includes shared libraries and reclaimable mappings.
- **WebKit helper processes** are launched by launchd rather than by the application. The script attributes WebKit and Quick Look processes that appear after FeatherView starts to FeatherView. No other WebKit application, such as Safari, was running.
- **Isolation.** Each application runs with a fresh profile in a temporary directory: VS Code with `--user-data-dir` and `--extensions-dir`, Zed with `--user-data-dir`, Chrome with `--user-data-dir`, and FeatherView as a copy with a different bundle identifier and therefore its own preferences domain. The user's own settings, sessions and extensions are not read or modified. The script terminates only the processes it started and removes its temporary files on exit.
- **Each run uses a new workspace path** (an APFS clone, which takes no extra disk space). Otherwise VS Code and Zed restore the previous run's tabs and the readings come out high.
- **Warm-up.** Each application is launched once before measurement so that first-run initialization (profile directories, caches) is not counted.
- **Settings slightly favouring VS Code:** telemetry, update checks and the startup welcome page are disabled.
- **Zed must be started through `Zed.app/Contents/MacOS/zed`.** The `cli` wrapper hands requests to an already running Zed and ignores `--user-data-dir`.

## Reproducing

```bash
make
scripts/bench.sh 3 20 > results.tsv      # about 20 minutes; the applications' windows appear in turn
ONLY=Zed scripts/bench.sh 3 20           # measure a single editor
```

VS Code, Zed and Chrome must be installed. The script locates them through Spotlight; set `ZED_APP=…` or `CHROME_APP=…` to use other paths. Do not use the computer during the run, and quit Safari beforehand.
