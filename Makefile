NAME     := FeatherView
APP      := build/$(NAME).app
BIN      := $(APP)/Contents/MacOS/$(NAME)
ICNS     := $(APP)/Contents/Resources/$(NAME).icns

MODULES  := App Editor Files Search Preview Viewers
SRC      := $(foreach m,$(MODULES),$(wildcard src/$(m)/*.m))
HDR      := $(foreach m,$(MODULES),$(wildcard src/$(m)/*.h))
LIB_SRC  := $(filter-out src/App/main.m,$(SRC))
INC      := $(addprefix -Isrc/,$(MODULES))
ARCH     ?=
CFLAGS   := -O2 -fobjc-arc -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min=12.0 $(INC) $(ARCH)
FRAMEWORKS := -framework Cocoa -framework CoreText -framework ImageIO -framework UniformTypeIdentifiers \
              -framework WebKit -framework PDFKit -lsqlite3
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Foundation-only code, tested without AppKit
CORE_SRC := src/Editor/PieceTable.m src/Editor/PieceTable+Search.m src/Files/FileKind.m src/Files/FileWalker.m \
            src/Files/FileOps.m src/Search/WorkspaceSearch.m src/Preview/TableModel.m src/Preview/JSONTree.m src/Preview/Notebook.m
MD_SRC   := src/Preview/Markdown.m src/Preview/MarkdownInline.m

.PHONY: all run test clean install release

all: $(BIN) $(ICNS) $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP) >/dev/null 2>&1 || true
	@# keep Finder's "Open With" pointing at the installed copy, not this build folder
	@$(LSREGISTER) -u "$(CURDIR)/$(APP)" >/dev/null 2>&1 || true

$(BIN): $(SRC) $(HDR)
	@mkdir -p $(dir $@)
	clang $(CFLAGS) $(FRAMEWORKS) -o $@ $(SRC)

$(APP)/Contents/Info.plist: Info.plist
	@mkdir -p $(dir $@)
	cp $< $@

build/make_icon: tools/make_icon.m
	@mkdir -p build
	clang -O2 -fobjc-arc -Wall -mmacosx-version-min=12.0 -framework Cocoa -o $@ $<

$(ICNS): build/make_icon
	@mkdir -p $(dir $@)
	rm -rf build/$(NAME).iconset
	./build/make_icon build/$(NAME).iconset
	iconutil -c icns build/$(NAME).iconset -o $@

build/tests: tests/tests.m $(CORE_SRC)
	@mkdir -p build
	clang $(CFLAGS) -framework Foundation -framework UniformTypeIdentifiers -o $@ $^

build/editor_tests: tests/editor_tests.m $(LIB_SRC) $(HDR)
	@mkdir -p build
	clang $(CFLAGS) $(FRAMEWORKS) -o $@ tests/editor_tests.m $(LIB_SRC)

build/markdown_tests: tests/markdown_tests.m $(MD_SRC) src/Preview/Markdown.h
	@mkdir -p build
	clang $(CFLAGS) -framework Foundation -o $@ tests/markdown_tests.m $(MD_SRC)

test: build/tests build/markdown_tests build/editor_tests
	./build/tests
	./build/markdown_tests
	./build/editor_tests

run: all
	open $(APP) --args "$(CURDIR)"

install: all
	./scripts/install.sh

# Universal (arm64 + x86_64) build, zipped with its checksum into dist/.
release:
	./scripts/release.sh

clean:
	rm -rf build dist
