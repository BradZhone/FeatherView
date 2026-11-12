# Changelog

[简体中文](CHANGELOG.zh-Hans.md)

All notable changes to FeatherView are documented here. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows [Semantic Versioning](https://semver.org/). Before 1.0, minor versions may contain incompatible changes.

## [0.21.0] — 2026-11-12

### Added

- An integrated terminal. ⌃` shows or hides the bottom panel; ⌥⌘T opens a new terminal (a terminal button sits at the right end of the status bar); File → Open Terminal Here starts one in the selected folder (or the workspace root). New terminals start in the workspace; the terminal strip shows each shell's current directory. Terminals run your login shell with a 256-color + truecolor terminal emulator written for FeatherView, with scrollback of 5,000 lines per terminal.
- A terminal lives either in the bottom panel (a strip of terminals, dragged taller from its top edge) or in a regular tab; moving between the two keeps the session, output and scrollback. Closing one ends its process without asking; quitting the app ends every open shell, and shells left behind by an earlier crash are cleaned up on the next launch.
- Terminal input: all keys reach the shell (arrows, ⌃-combinations, ⌥-prefixes), Chinese and other input methods compose at the cursor, ⌘C copies the selection (or sends an interrupt without one), ⌘V pastes with bracketed-paste when the program asks, ⌘K clears screen and scrollback, ⌘= / ⌘- change the font size. Programs that turn on mouse reporting (less, htop) receive clicks and wheel events; otherwise the wheel scrolls back through history. URLs underline on hover and open on click. Colors follow the light / dark appearance.

## [0.20.0] — 2026-11-11

### Added

- Code folding. Regions follow indentation (Markdown: headings, skipping code blocks). Fold (⌥⌘[), Unfold (⌥⌘]), Fold All (⇧⌥⌘[) and Unfold All (⇧⌥⌘]) are in the View menu; the control next to the line number folds a region, and clicking the ⋯ after a folded line opens it. Folds follow edits made elsewhere, and a caret that reaches folded lines (Go to Line, find, undo) opens them.
- Indent guides, on by default, and Show Whitespace (dots for spaces, arrows for tabs), off by default; both are in the View menu and in Settings.
- Expand Selection (⌃⇧⌘→) grows each selection to the word, the string, the bracket contents, the brackets, the line and the whole text; Shrink Selection (⌃⇧⌘←) goes back.
- The indentation step of a file (2, 4 or 8 spaces) is detected, and Tab, backspace in the indentation and the indent guides use it.

## [0.19.0] — 2026-11-10

### Added

- Multiple cursors. ⌥-click adds or removes a cursor, ⇧⌥-drag selects a column, ⌥⌘↑ / ⌥⌘↓ add a cursor on the line above or below, ⌥⌘I puts one at the end of every selected line, ⌘D selects the word and then adds its next occurrence, ⇧⌘D moves the last selection to the next occurrence, ⇧⌘L selects all occurrences, ⌘U takes the last cursor change back and Esc returns to one cursor. Typing, deleting, moving, input methods, copy and paste (one piece per cursor when the counts match) work at every cursor, and each change is one undo step that restores all cursors. Up to 10,000 cursors; typing a word at all of them in a 2 MB file takes about 50 ms.
- A Selection menu with line commands: move line up / down (⌥↑ / ⌥↓), copy line up / down (⇧⌥↑ / ⇧⌥↓), delete line (⇧⌘K), insert line below / above (⌘↩ / ⇧⌘↩), join lines (⌃J), indent / outdent (⌘] / ⌘[), toggle line comment (⌘/, with the language's comment syntax), go to matching bracket (⇧⌘\), sort lines, trim trailing whitespace, and upper / lower case. Its shortcuts apply only while a text editor has the focus.
- Brackets and quotes close automatically, selections are wrapped when an opening bracket or quote is typed, a closing one that was added automatically is typed over, and backspace removes an empty pair. Quotes are not closed in plain text and Markdown. It can be turned off in Settings.
- The matching bracket is outlined, the caret's line is shaded, and other occurrences of the word at the caret (or of the selected text) are marked.
- Enter after `{`, `[`, `(` or a Python `:` indents one more level, and between a pair of brackets puts the closing one on its own line. Backspace in the indentation removes spaces back to the previous tab stop, and Tab inserts spaces to the next one.
- ⌘C and ⌘X without a selection copy or cut the whole line, and such a line is pasted above the caret's line.
- ⌃G goes to a line, as well as ⌘L.

### Changed

- ⌘← goes to the first non-blank character of the line, and a second press to its start; ⌃A always goes to the start.

## [0.18.0] — 2026-11-10

### Added

- Excel workbooks (.xlsx, .xlsm) open in a spreadsheet view: sheet tabs, column letters and row numbers, number and date formats, fonts, fills, borders, merged cells, column widths, hidden rows and columns, and frozen panes. Cells can be edited in place or in the formula bar, with undo, copy and paste, and find. Saving (⌘S) writes only the edited cells back into the file; every other part of the workbook is kept byte for byte, and Excel or Numbers recalculates formulas when the file is next opened. Shared-formula sources, array formulas, table header rows, merged cells and protected sheets are read-only, with the reason shown. Workbooks are never auto-saved.
- Word documents (.docx, .doc, .rtf, .odt) are rendered by the system's Office renderer as pages, with zoom and find, read-only. "Open in Pages" (or Word, WPS Office …) hands the file to an app that can edit it.

### Fixed

- YAML (`---`) and TOML (`+++`) front matter at the top of a Markdown file is shown as a property table instead of being rendered as a heading.

## [0.17.0] — 2026-11-09

A reliability release: data-loss, security and crash fixes found in a full review, each with a regression test.

### Fixed — data safety

- ⌘S works again on a new document after its draft has been backed up.
- Quitting after the main window was closed and reopened asks about unsaved changes again, and the window brings its tabs back.
- Backspace and Delete on a line longer than 32 KB remove one character instead of the hidden part of the line (up to 13 KB at once).
- Read-only files are no longer replaced by ⌘S or auto-save; the status bar says the file is read-only.
- Saving a draft over a file that is open in another tab asks first when that tab has unsaved changes, and leaves a single tab for the file.
- Replace All keeps the caret on the same text, never inside a multi-byte character.
- A draft containing a NUL byte comes back as text, not hex. Drafts no session refers to (after a crash) are reopened as tabs instead of being deleted after a week. The saved session of a workspace on a disk that is not mounted is kept.
- Saving keeps extended attributes (Finder tags, quarantine) and ACLs, keeps hard links pointing at the same file, saves UTF-16 in its original byte order, and works in a read-only folder when the file itself is writable.

### Fixed — security

- An archive entry that is a symbolic link is no longer extracted and opened, so saving the "copy" can't write to a file outside the archive.
- In the HTML preview, a page script can no longer open links or windows by itself; links open only right after a click or key press.
- A file-type filter in workspace search no longer brings back hidden files or files excluded by `.gitignore`.
- Queries in the SQLite viewer can't write files: `VACUUM INTO`, `ATTACH` and other writing statements are refused.
- Links in PDFs open only for web and mail addresses; links to local files open in a tab.

### Fixed — crashes and freezes

- Markdown: deeply nested lists or quotes no longer crash the preview, and emphasis, links and code spans are parsed in linear time (a 120 KB paragraph took up to 15 s).
- A small binary property list that expands exponentially is cut off at 2 million nodes instead of exhausting memory.
- A CSV with hundreds of thousands of columns shows the first 1,000.
- Notebooks with unexpected metadata types render instead of throwing.
- A regular expression with catastrophic backtracking gives up on the line instead of hanging the search, and a new search cancels it.
- Replace All, its undo and its redo with 100,000 matches take milliseconds instead of minutes.
- A slow SQLite query is stopped by the next one instead of blocking it.

### Fixed — other

- Text in Shift-JIS, EUC-JP, EUC-KR, Big5 and Windows-1252 is detected correctly instead of as garbled GB18030; the status bar names the encoding.
- WAL-mode SQLite databases in read-only folders show their tables, including changes not yet checkpointed.
- Archive entries with non-ASCII names, or with `*` or `[` in the name, extract correctly. Old temporary copies are removed.
- Workspace search reports ripgrep errors instead of "No results", falls back to the built-in scanner for regular expressions ripgrep can't parse, finds matches beyond column 4,000, follows a symlinked workspace folder, and ignores the user's ripgrep configuration file.
- ⌘W in Settings or another panel closes that window, not a tab behind it, and works in an empty main window. Save All carries on past a cancelled save panel. Reopen Closed Tab stays within the current workspace.
- Press-and-hold accents replace the letter instead of adding to it. Text inserted by dictation gets the file's line endings. After Home or End, moving up or down keeps the new column. Undoing past the 2,000-step history limit no longer marks the file as saved.
- Close All no longer loads every remaining tab while closing. Settings keeps a list typed without pressing Return.
- The Default Apps panel's "and N more" count was one too high.
- A click during IME composition commits the text instead of discarding it.

### Added

- The workspace folder is watched: files created, renamed or deleted outside FeatherView appear in the tree and search without a manual refresh. Folders are re-read in the background.
- Drag files onto the window to open them, or a folder to make it the workspace.
- Tab and Shift-Tab indent and outdent every selected line.
- Find and Replace All are case-insensitive for all scripts (`Ä` finds `ä`), not only ASCII.
- Option-arrow and double-click stop at word boundaries in Chinese and Japanese text.
- Emacs-style keys: ⌃K, ⌃Y, ⌃T, ⌃O and the paragraph motions.
- Dragging a selection above or below the editor keeps scrolling while the mouse is held there.
- VoiceOver: insertion line, selected text and selection range, with change notifications.
- A Window menu.
- Settings → Previews: turn off web images in the Markdown preview.
- `make sanitize` (tests under AddressSanitizer and UndefinedBehaviorSanitizer) and `make analyze` (clang static analyzer).

### Changed

- Word Wrap is now ⌥⌘Z. ⌥Z types a character on many keyboard layouts (Ω on US, ż on Polish).
- ⌘S on a file without changes does nothing, instead of beeping.

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

[0.18.0]: https://github.com/BradZhone/FeatherView/releases/tag/v0.18.0
[0.17.0]: https://github.com/BradZhone/feather/releases/tag/v0.17.0
[0.16.0]: https://github.com/BradZhone/feather/releases/tag/v0.16.0
[0.15.0]: https://github.com/BradZhone/feather/releases/tag/v0.15.0
