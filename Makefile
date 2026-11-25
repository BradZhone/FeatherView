NAME     := FeatherView
APP      := build/$(NAME).app
BIN      := $(APP)/Contents/MacOS/$(NAME)
ICNS     := $(APP)/Contents/Resources/$(NAME).icns

MODULES  := Support App Editor Files Search Preview Viewers Terminal
SRC      := $(foreach m,$(MODULES),$(wildcard src/$(m)/*.m))
HDR      := $(foreach m,$(MODULES),$(wildcard src/$(m)/*.h))
LIB_SRC  := $(filter-out src/App/main.m,$(SRC))
INC      := $(addprefix -Isrc/,$(MODULES))
ARCH     ?=
CFLAGS   := -O2 -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Wno-nullability-completeness -mmacosx-version-min=12.0 $(INC) $(ARCH)
FRAMEWORKS := -framework Cocoa -framework CoreText -framework ImageIO -framework UniformTypeIdentifiers \
              -framework Carbon \
              -framework WebKit -framework PDFKit -framework CoreServices -lsqlite3 -lz
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Foundation-only code, tested without AppKit
CORE_SRC := src/Support/Localization.m src/Editor/PieceTable.m src/Editor/PieceTable+Search.m src/Files/FileKind.m src/Files/FileWalker.m \
            src/Files/FileOps.m src/Search/WorkspaceSearch.m src/Preview/TableModel.m src/Preview/JSONTree.m src/Preview/Notebook.m \
            src/Files/ZipArchive.m src/Preview/XLXML.m src/Preview/XLNumberFormat.m src/Preview/XLStyles.m src/Preview/XLWorkbook.m \
            src/Preview/XLSheet.m src/Preview/XLSheetEdit.m src/Preview/XLSave.m \
            src/Terminal/TScreen.m src/Terminal/VTEscape.m src/Terminal/TSession.m
MD_SRC   := src/Preview/Markdown.m src/Preview/MarkdownInline.m

.PHONY: all run test clean install release sanitize analyze

RES      := $(patsubst Resources/%,$(APP)/Contents/Resources/%,$(wildcard Resources/*.lproj/*.strings))

all: $(BIN) $(ICNS) $(APP)/Contents/Info.plist $(RES)
	codesign --force --sign - $(APP) >/dev/null 2>&1 || true
	@# keep Finder's "Open With" pointing at the installed copy, not this build folder
	@$(LSREGISTER) -u "$(CURDIR)/$(APP)" >/dev/null 2>&1 || true

$(BIN): $(SRC) $(HDR)
	@mkdir -p $(dir $@)
	clang $(CFLAGS) $(FRAMEWORKS) -o $@ $(SRC)

$(APP)/Contents/Info.plist: Info.plist
	@mkdir -p $(dir $@)
	cp $< $@

# .strings are compiled to binary plists, as Xcode does
$(APP)/Contents/Resources/%.strings: Resources/%.strings
	@mkdir -p $(dir $@)
	plutil -convert binary1 -o $@ $<

build/make_icon: tools/make_icon.m
	@mkdir -p build
	clang -O2 -fobjc-arc -Wall -mmacosx-version-min=12.0 -framework Cocoa -o $@ $<

$(ICNS): build/make_icon
	@mkdir -p $(dir $@)
	rm -rf build/$(NAME).iconset
	./build/make_icon build/$(NAME).iconset
	iconutil -c icns build/$(NAME).iconset -o $@

build/tests: tests/tests.m tests/xlsx_fixture.h $(CORE_SRC)
	@mkdir -p build
	clang $(CFLAGS) -framework Foundation -framework UniformTypeIdentifiers -lz -o $@ tests/tests.m $(CORE_SRC)

build/editor_tests: tests/editor_tests.m tests/xlsx_fixture.h $(LIB_SRC) $(HDR)
	@mkdir -p build
	clang $(CFLAGS) $(FRAMEWORKS) -o $@ tests/editor_tests.m $(LIB_SRC)

build/terminal_tests: tests/terminal_tests.m $(CORE_SRC)
	@mkdir -p build
	clang $(CFLAGS) -framework Foundation -framework UniformTypeIdentifiers -lz -o $@ tests/terminal_tests.m $(CORE_SRC)

build/editing_tests: tests/editing_tests.m $(LIB_SRC) $(HDR)
	@mkdir -p build
	clang $(CFLAGS) $(FRAMEWORKS) -o $@ tests/editing_tests.m $(LIB_SRC)

build/session_lifecycle_tests: tests/session_lifecycle_tests.m $(LIB_SRC) $(HDR)
	@mkdir -p build
	clang $(CFLAGS) $(FRAMEWORKS) -o $@ tests/session_lifecycle_tests.m $(LIB_SRC)

build/terminal_input_tests: tests/terminal_input_tests.m $(LIB_SRC) $(HDR)
	@mkdir -p build
	clang $(CFLAGS) $(FRAMEWORKS) -o $@ tests/terminal_input_tests.m $(LIB_SRC)

build/file_tree_tests: tests/file_tree_tests.m $(LIB_SRC) $(HDR)
	@mkdir -p build
	clang $(CFLAGS) $(FRAMEWORKS) -o $@ tests/file_tree_tests.m $(LIB_SRC)

build/tab_drag_tests: tests/tab_drag_tests.m $(LIB_SRC) $(HDR)
	@mkdir -p build
	clang $(CFLAGS) $(FRAMEWORKS) -o $@ tests/tab_drag_tests.m $(LIB_SRC)

build/float_panel_tests: tests/float_panel_tests.m $(LIB_SRC) $(HDR)
	@mkdir -p build
	clang $(CFLAGS) $(FRAMEWORKS) -o $@ tests/float_panel_tests.m $(LIB_SRC)

build/markdown_tests: tests/markdown_tests.m $(MD_SRC) src/Preview/Markdown.h
	@mkdir -p build
	clang $(CFLAGS) -framework Foundation -o $@ tests/markdown_tests.m $(MD_SRC)

# Each test process gets private defaults, shell configuration and PID records. AppDelegate tests
# must never sweep real user terminals, even while the installed app stays open.
TEST_RUN = bash -c 'set -e; d=$$(mktemp -d "$${TMPDIR:-/tmp}/feather-tests.XXXXXX"); trap "rm -rf -- \"$$d\"" EXIT; CFFIXED_USER_HOME="$$d" FEATHERVIEW_TERMINAL_PIDS_DIR="$$d/pids" ZDOTDIR="$$d" SHELL=/bin/sh "$$@"' --

test: build/tests build/markdown_tests build/terminal_tests build/editor_tests build/editing_tests build/session_lifecycle_tests build/terminal_input_tests build/file_tree_tests build/tab_drag_tests build/float_panel_tests
	python3 scripts/l10n.py
	$(TEST_RUN) ./build/tests
	$(TEST_RUN) ./build/markdown_tests
	$(TEST_RUN) ./build/terminal_tests
	$(TEST_RUN) ./build/editing_tests
	$(TEST_RUN) ./build/editor_tests
	$(TEST_RUN) ./build/session_lifecycle_tests
	$(TEST_RUN) ./build/terminal_input_tests
	$(TEST_RUN) ./build/file_tree_tests
	$(TEST_RUN) ./build/tab_drag_tests
	$(TEST_RUN) ./build/float_panel_tests

# Test programs built with AddressSanitizer and UndefinedBehaviorSanitizer, in build/san.
SAN := -fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer -g -O1
sanitize:
	@mkdir -p build/san
	clang $(filter-out -O2,$(CFLAGS)) $(SAN) -framework Foundation -framework UniformTypeIdentifiers -lz -o build/san/tests tests/tests.m $(CORE_SRC)
	clang $(filter-out -O2,$(CFLAGS)) $(SAN) -framework Foundation -framework UniformTypeIdentifiers -lz -o build/san/terminal_tests tests/terminal_tests.m $(CORE_SRC)
	clang $(filter-out -O2,$(CFLAGS)) $(SAN) -framework Foundation -o build/san/markdown_tests tests/markdown_tests.m $(MD_SRC)
	clang $(filter-out -O2,$(CFLAGS)) $(SAN) $(FRAMEWORKS) -o build/san/editor_tests tests/editor_tests.m $(LIB_SRC)
	clang $(filter-out -O2,$(CFLAGS)) $(SAN) $(FRAMEWORKS) -o build/san/editing_tests tests/editing_tests.m $(LIB_SRC)
	clang $(filter-out -O2,$(CFLAGS)) $(SAN) $(FRAMEWORKS) -o build/san/session_lifecycle_tests tests/session_lifecycle_tests.m $(LIB_SRC)
	clang $(filter-out -O2,$(CFLAGS)) $(SAN) $(FRAMEWORKS) -o build/san/terminal_input_tests tests/terminal_input_tests.m $(LIB_SRC)
	clang $(filter-out -O2,$(CFLAGS)) $(SAN) $(FRAMEWORKS) -o build/san/file_tree_tests tests/file_tree_tests.m $(LIB_SRC)
	clang $(filter-out -O2,$(CFLAGS)) $(SAN) $(FRAMEWORKS) -o build/san/tab_drag_tests tests/tab_drag_tests.m $(LIB_SRC)
	clang $(filter-out -O2,$(CFLAGS)) $(SAN) $(FRAMEWORKS) -o build/san/float_panel_tests tests/float_panel_tests.m $(LIB_SRC)

	$(TEST_RUN) ./build/san/tests
	$(TEST_RUN) ./build/san/terminal_tests
	$(TEST_RUN) ./build/san/markdown_tests
	$(TEST_RUN) ./build/san/editing_tests
	$(TEST_RUN) ./build/san/editor_tests
	$(TEST_RUN) ./build/san/session_lifecycle_tests
	$(TEST_RUN) ./build/san/terminal_input_tests
	$(TEST_RUN) ./build/san/file_tree_tests
	$(TEST_RUN) ./build/san/tab_drag_tests
	$(TEST_RUN) ./build/san/float_panel_tests



# clang's static analyzer over every source file; fails on any finding.
analyze:
	@for f in $(SRC); do clang --analyze -Xanalyzer -analyzer-output=text -fobjc-arc $(INC) -mmacosx-version-min=12.0 $$f -o /dev/null 2>&1; done | tee build/analyze.txt
	@! grep -q "warning:" build/analyze.txt

run: all
	open $(APP) --args "$(CURDIR)"

install: all
	./scripts/install.sh

# Universal (arm64 + x86_64) build, zipped with its checksum into dist/.
release:
	./scripts/release.sh

clean:
	rm -rf build dist
