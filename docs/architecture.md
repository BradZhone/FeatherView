# Architecture

[简体中文](architecture.zh-Hans.md)

FeatherView is an Objective-C application built on AppKit. It has no third-party dependencies and is built by `make`, which invokes clang directly. One goal drives the design: **provide viewing and light editing in a single native process with as little memory as possible.** The decisions below follow from it.

## Source layout

```
src/
  Support/   Localization (FTL / FTLP)
  App/       Entry point, window, menus, tab and document management (ContentController), settings,
             welcome page, default-app selection
  Editor/    Text editor: PieceTable buffer; TextEditorView (drawing, input, soft wrap, minimap, search);
             syntax highlighting; tab bar
  Files/     File tree, directory traversal and filtering, file operations, type detection, file icons
  Search/    Workspace search (ripgrep or a built-in walker), search panel, Quick Open
  Preview/   Markdown parser and native renderer, HTML preview, table, tree and notebook views and their models
  Viewers/   Image, SVG, PDF, hex, SQLite and archive viewers
Resources/   <lang>.lproj string tables
tests/       Three test programs: Foundation-only logic, Markdown parsing, live views in an offscreen window
tools/       Application icon, drawn in code
scripts/     Installation, release packaging, benchmark, localization check, Info.plist document types
docs/        This document and the benchmark
```

Modules include each other's headers directly. The Makefile adds an `-I` flag for every module, so `#import "FileKind.h"` needs no path.

## Design decisions

**The editor does not use NSTextView.** `TextEditorView` is a self-scrolling `CanvasView` that lays out only the visible lines with CoreText on each frame. Text is stored in a `PieceTable`: the original file is memory-mapped rather than copied, edits are appended to an add buffer, and a table of line-start offsets is maintained alongside. Opening a 100 MB log therefore costs about the same memory as opening a 1 KB file; see the [benchmark](benchmark.md).

**Soft wrap uses prefix sums.** When wrapping is on, `_rowStart[L]` holds the first visual row of logical line L. Converting between lines and rows is a binary search, and an edit re-measures only the lines it touched before shifting the rest, which costs about 0.04 ms per keystroke in a 100,000-line file. The break rules — after spaces and after characters such as `-`, `/` and `,`; between CJK characters; never placing `，` or `。` at the start of a row; indenting continuation rows like their line — live in a single function, `rowsOf:width:`. Table construction, drawing, hit testing and caret movement all share it, so what is drawn and what is clicked cannot disagree. When the width changes, the table is rebuilt with the logical line at the top of the view as the anchor, so the content does not jump.

**Markdown is rendered natively; only HTML uses WebKit.** A WKWebView starts three helper processes (GPU, WebContent and Networking), measured at about 70 MB, which remain until the application quits. Markdown is therefore converted by FeatherView's own parser into TextKit attributed text, and a WebView is created only when an `.html` file is actually opened. Sessions that never display HTML never pay for it.

**Data views parse on demand.** CSV cells are stored as byte ranges (arrays of `uint32`) rather than as one string per cell. JSON is read by FeatherView's own parser, which preserves key order and line numbers so that "Show in Source" can jump to the right place. SQLite files are opened read-only and queried in pages. Archives are listed with the system `bsdtar`.

**Images are decoded at display size.** ImageIO decodes only the pixels needed for the current zoom level and decodes again when zooming in, up to 24 megapixels.

**Default apps are never taken over.** Every document type in `Info.plist` uses `LSHandlerRank None`. After installation FeatherView appears under "Open With" but never becomes the default for any file type on its own; a default changes only when the user selects it in the Default Apps panel. `tests/tests.m` verifies this.

**User interface text is localized.** English is the development language, and the English text itself is the key: `FTL(@"Save All")`. Count-dependent text uses `FTLP(n, @"%lu file", @"%lu files")`, which selects the singular form for exactly one in English. Translations live in `Resources/<lang>.lproj/Localizable.strings`; macOS chooses the language from the user's preferred-language order (Simplified Chinese for `zh-Hans`, English otherwise). `scripts/l10n.py` runs as part of `make test` and fails if a key lacks a translation, if format specifiers differ between a key and its translation, if a translation is unused, or if Chinese text appears in the sources outside the string tables.

## Tests

```bash
make test
```

- `scripts/l10n.py`: translation coverage and format-specifier consistency.
- `build/tests`: logic tests for the piece table, traversal and filtering, search options, and CSV, JSON and notebook parsing.
- `build/markdown_tests`: 54 Markdown parsing cases.
- `build/editor_tests`: drives the real editor, file tree, tabs, previews and viewers in an offscreen window, checking behaviour, pixels and performance — for example, "a minimap frame on a 100,000-line file takes under 16 ms" and "after every edit, the incrementally maintained wrap table equals a full rebuild". It also renders the menus and status bar in both languages.

The tests never touch the user's clipboard, Trash, untitled-document backups or real settings: they use a private pasteboard, an injectable trash handler and temporary directories.
