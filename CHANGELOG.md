# Changelog

[简体中文](CHANGELOG.zh-Hans.md)

All notable changes to FeatherView are documented here. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows [Semantic Versioning](https://semver.org/). Before 1.0, minor versions may contain incompatible changes.

## [0.16.0] — 2026-11-06

### Added

- English user interface. English is now the development language, with a Simplified Chinese translation; macOS selects the language from the system's preferred-language order. A language can be set for FeatherView alone under System Settings → General → Language & Region → Applications.
- Correct singular and plural forms for counts in English ("1 file", "2 files").
- `scripts/l10n.py`, run by `make test`, which checks that every user-interface string is translated with matching format specifiers.
- English documentation as the default, with Simplified Chinese versions of the README, benchmark, architecture and contributing documents.

### Changed

- Documentation rewritten in a more formal style.
- English labels were fitted to the existing layouts: the Settings window now has proper margins, and the Default Apps panel has a wider name column.

## [0.15.0] — 2026-11-06

First packaged release. The project was renamed **FeatherView**.

### Added

- Soft wrap in the editor that follows the window width. Breaks occur at word boundaries, between CJK characters (closing punctuation never starts a row), and continuation rows keep the line's indentation. Toggle with ⌥Z or in Settings; on by default. Files over one million lines or 32 MB are not wrapped, as noted in the status bar.
- Tab stops every four columns (previously about 3.6).
- Multiple `--open <file>` arguments on the command line.
- `scripts/release.sh` for universal (arm64 + x86_64) packages and `scripts/bench.sh` for the resource comparison.
- README, benchmark, architecture notes, contributing guide and MIT license.

### Changed

- The application, its menus and its install location are now FeatherView.app. The bundle identifier remains `local.feather.editor`, so existing settings, sessions, recent workspaces and default-app choices are kept. `make install` moves an old Feather.app to the Trash.
- Sources split into the modules `src/App`, `Editor`, `Files`, `Search`, `Preview` and `Viewers`.

## [0.14] — 2026-11-06

- CSV, TSV and JSON Lines shown as sortable, filterable tables.
- JSON and property lists (including binary) shown as collapsible trees; Jupyter notebooks rendered as documents.
- Read-only SQLite browser; archive listing with double-click to extract and open.
- Settings window (⌘,): appearance, hidden files, always-hidden names, search exclusions, `.gitignore`, auto-save, minimap.

## [0.13]

- Untitled documents (⌘N) kept as drafts until closed, as in VS Code.
- Light, dark and system appearance; recent workspaces can be removed individually.
- The Default Apps panel explains that only a web browser can be the default for `.html`.

## [0.12] and earlier

- Workspace search (all, file names, contents; match case, whole word, regular expressions; include and exclude paths).
- Multi-selection and batch operations in the file tree; SVG and TypeScript detection; new icon and colour scheme.
- Native Markdown rendering, HTML preview, image, PDF and hex viewers, minimap, auto-save, session restore.

[0.16.0]: https://github.com/BradZhone/feather/releases/tag/v0.16.0
[0.15.0]: https://github.com/BradZhone/feather/releases/tag/v0.15.0
