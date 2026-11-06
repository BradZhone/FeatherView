APP      := build/Feather.app
BIN      := $(APP)/Contents/MacOS/Feather
ICNS     := $(APP)/Contents/Resources/Feather.icns
SRC      := $(wildcard src/*.m)
LIB_SRC  := $(filter-out src/main.m,$(SRC))
CFLAGS   := -O2 -fobjc-arc -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min=12.0
FRAMEWORKS := -framework Cocoa -framework CoreText -framework ImageIO -framework UniformTypeIdentifiers -framework WebKit -framework PDFKit

.PHONY: all run test clean measure install

all: $(BIN) $(ICNS) $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP) >/dev/null 2>&1 || true

$(BIN): $(SRC) $(wildcard src/*.h)
	@mkdir -p $(dir $@)
	clang $(CFLAGS) $(FRAMEWORKS) -o $@ $(SRC)

$(APP)/Contents/Info.plist: Info.plist
	@mkdir -p $(dir $@)
	cp $< $@

build/make_icon: tools/make_icon.m
	@mkdir -p build
	clang $(CFLAGS) -framework Cocoa -o $@ $<

$(ICNS): build/make_icon
	@mkdir -p $(dir $@)
	rm -rf build/Feather.iconset
	./build/make_icon build/Feather.iconset
	iconutil -c icns build/Feather.iconset -o $@

build/tests: tests/tests.m src/PieceTable.m src/PieceTable+Search.m src/FileKind.m src/FileWalker.m src/FileOps.m src/WorkspaceSearch.m
	@mkdir -p build
	clang $(CFLAGS) -Isrc -framework Foundation -framework UniformTypeIdentifiers -o $@ $^

build/editor_tests: tests/editor_tests.m $(LIB_SRC) $(wildcard src/*.h)
	@mkdir -p build
	clang $(CFLAGS) -Isrc $(FRAMEWORKS) -o $@ tests/editor_tests.m $(LIB_SRC)

build/markdown_tests: tests/markdown_tests.m src/Markdown.m src/MarkdownInline.m src/Markdown.h
	@mkdir -p build
	clang $(CFLAGS) -Isrc -framework Foundation -o $@ tests/markdown_tests.m src/Markdown.m src/MarkdownInline.m

test: build/tests build/markdown_tests build/editor_tests
	./build/tests
	./build/markdown_tests
	./build/editor_tests

run: all
	open $(APP) --args "$(CURDIR)"

measure: all
	./scripts/measure.sh

install: all
	./scripts/install.sh

clean:
	rm -rf build
