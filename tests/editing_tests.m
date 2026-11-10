// Multiple cursors, line commands and typing aids, on a TextEditorView in an offscreen window.
// Text with cursors is written as markup: "|" is a caret, "[x|]" / "[|x]" a selection (caret at the bar).
#import <Cocoa/Cocoa.h>
#import "TextEditorView+Private.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while (0)

static NSWindow *win;
static NSPasteboard *pb;

static NSString *text(TextEditorView *ed) {
    return [[NSString alloc] initWithData:[ed->_buf dataInRange:NSMakeRange(0, ed->_buf.length)] encoding:NSUTF8StringEncoding];
}

// Parses markup into text and cursors (byte offsets).
static NSString *parse(NSString *m, NSMutableData *sels, NSUInteger *primary) {
    NSMutableData *out = [NSMutableData data];
    NSData *d = [m dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *b = d.bytes;
    NSUInteger open = NSNotFound, bar = NSNotFound;
    for (NSUInteger i = 0; i < d.length; i++) {
        NSUInteger at = out.length;
        if (b[i] == '[') { open = at; bar = NSNotFound; continue; }
        if (b[i] == '|') {
            if (open == NSNotFound) { Sel s = SelMake(at, at); [sels appendBytes:&s length:sizeof s]; }
            else bar = at;
            continue;
        }
        if (b[i] == ']') {
            Sel s = bar == open ? SelMake(at, open) : SelMake(open, at);
            [sels appendBytes:&s length:sizeof s];
            open = NSNotFound;
            continue;
        }
        [out appendBytes:&b[i] length:1];
    }
    if (primary) *primary = sels.length / sizeof(Sel) - 1;
    return [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];
}

// The text with the cursors written into it.
static NSString *show(TextEditorView *ed) {
    NSData *d = [ed->_buf dataInRange:NSMakeRange(0, ed->_buf.length)];
    NSUInteger p = 0;
    NSData *cur = [ed cursors:&p];
    const Sel *c = cur.bytes;
    NSUInteger n = cur.length / sizeof(Sel);
    NSMutableString *out = [NSMutableString string];
    const uint8_t *b = d.bytes;
    NSUInteger k = 0;
    for (NSUInteger i = 0; i <= d.length; i++) {
        while (k < n && SelEnd(c[k]) == i && SelStart(c[k]) < i) { [out appendString:c[k].caret == i ? @"|]" : @"]"]; k++; }
        for (NSUInteger j = k; j < n && SelStart(c[j]) == i; j++) {
            if (SelEnd(c[j]) == i) { [out appendString:@"|"]; if (j == k) k++; }
            else [out appendString:c[j].caret == i ? @"[|" : @"["];
        }
        if (i < d.length) {
            NSUInteger len = b[i] < 0x80 ? 1 : b[i] < 0xE0 ? 2 : b[i] < 0xF0 ? 3 : 4;
            [out appendString:[[NSString alloc] initWithBytes:b + i length:len encoding:NSUTF8StringEncoding] ?: @"?"];
            i += len - 1;
        }
    }
    return out;
}

static TextEditorView *editor(NSString *markup, NSString *name) {
    NSMutableData *sels = [NSMutableData data];
    NSUInteger primary = 0;
    NSString *t = parse(markup, sels, &primary);
    PieceTable *pt = [[PieceTable alloc] initWithData:[t dataUsingEncoding:NSUTF8StringEncoding]];
    TextEditorView *ed = [[TextEditorView alloc] initWithFrame:NSMakeRect(0, 0, 700, 500) buffer:pt
                                                          path:[@"/tmp" stringByAppendingPathComponent:name ?: @"t.c"]
                                                      encoding:NSUTF8StringEncoding];
    ed.pasteboard = pb;
    ed.wordWrap = NO;
    win.contentView = ed;
    [win makeFirstResponder:ed];
    if (sels.length) [ed setCursors:sels.bytes count:sels.length / sizeof(Sel) primary:primary];
    return ed;
}

static void type(TextEditorView *ed, NSString *s) {
    for (NSUInteger i = 0; i < s.length; i++)
        [ed insertText:[s substringWithRange:NSMakeRange(i, 1)] replacementRange:NSMakeRange(NSNotFound, 0)];
}

#define SHOWS(ed, expected, what) do { NSString *got_ = show(ed); CHECK([got_ isEqualToString:expected], "%s: got \"%s\" want \"%s\"", what, \
    [got_ stringByReplacingOccurrencesOfString:@"\n" withString:@"⏎"].UTF8String, [expected stringByReplacingOccurrencesOfString:@"\n" withString:@"⏎"].UTF8String); } while (0)

#pragma mark Multiple cursors

static void multiCursorTyping(void) {
    TextEditorView *ed = editor(@"a|b\nc|d\ne|f", nil);
    CHECK(ed.cursorCount == 3, "three cursors from the markup");
    type(ed, @"XY");
    SHOWS(ed, @"aXY|b\ncXY|d\neXY|f", "typing at three cursors");
    [ed undo:nil];
    SHOWS(ed, @"a|b\nc|d\ne|f", "one undo takes the typed run back, cursors included");
    [ed redo:nil];
    SHOWS(ed, @"aXY|b\ncXY|d\neXY|f", "redo");
    [ed deleteBackward:nil];
    [ed deleteBackward:nil];
    [ed deleteBackward:nil];
    SHOWS(ed, @"|b\n|d\n|f", "backspace at every cursor");
    [ed undo:nil];
    SHOWS(ed, @"aXY|b\ncXY|d\neXY|f", "the backspaces were one step");
    [ed deleteForward:nil];
    SHOWS(ed, @"aXY|\ncXY|\neXY|", "forward delete");

    // moving: cursors that meet become one
    ed = editor(@"|ab\n|cd", nil);
    [ed moveUp:nil];
    CHECK(ed.cursorCount == 1, "two cursors moved onto the same place merge (%lu)", (unsigned long)ed.cursorCount);
    ed = editor(@"ab|c\nde|f\ngh|i", nil);
    [ed moveRight:nil];
    SHOWS(ed, @"abc|\ndef|\nghi|", "→ at every cursor");
    [ed moveToLeftEndOfLineAndModifySelection:nil];
    SHOWS(ed, @"[|abc]\n[|def]\n[|ghi]", "⇧⌘← selects at every cursor");
    [ed moveLeft:nil];
    SHOWS(ed, @"|abc\n|def\n|ghi", "← collapses each selection to its start");
    [ed cancelOperation:nil];
    CHECK(ed.cursorCount == 1 && ed->_caret == 8, "Esc keeps only the primary (last added) cursor (at %lu)", (unsigned long)ed->_caret);

    // two cursors deleting the same word merge their edits
    ed = editor(@"foo|bar| baz", nil);
    [ed deleteWordBackward:nil];
    SHOWS(ed, @"| baz", "⌥⌫ from two cursors in one word");
    [ed undo:nil];
    CHECK([text(ed) isEqualToString:@"foobar baz"], "and undo brings the word back");

    // an input method composes at the primary cursor and commits at all of them
    ed = editor(@"a|\nb|", nil);
    [ed setMarkedText:@"ni" selectedRange:NSMakeRange(2, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK([text(ed) isEqualToString:@"a\nb"], "marked text stays out of the buffer");
    [ed displayIfNeeded];
    [ed insertText:@"你" replacementRange:NSMakeRange(NSNotFound, 0)];
    SHOWS(ed, @"a你|\nb你|", "committed text goes to every cursor");
    // typing over selections
    ed = editor(@"[x|] [y|] [z|]", nil);
    type(ed, @"Q");
    SHOWS(ed, @"Q| Q| Q|", "typing replaces each selection");
    [ed undo:nil];
    SHOWS(ed, @"[x|] [y|] [z|]", "undo restores the selections");
}

static void addingCursors(void) {
    TextEditorView *ed = editor(@"abcdef|gh\nab\nabcdefgh\n", nil);
    [ed addCursorBelow:nil];
    [ed addCursorBelow:nil];
    SHOWS(ed, @"abcdef|gh\nab|\nabcdef|gh\n", "⌥⌘↓ keeps the column across a short line");
    [ed undoCursor:nil];
    CHECK(ed.cursorCount == 2, "⌘U takes the last added cursor back (%lu)", (unsigned long)ed.cursorCount);
    [ed undoCursor:nil];
    CHECK(ed.cursorCount == 1, "and the one before");
    [ed addCursorAbove:nil];
    CHECK(ed.cursorCount == 1, "nothing above the first line");

    ed = editor(@"one [two\nthree\nfo|]ur", nil);
    [ed addCursorsToLineEnds:nil];
    SHOWS(ed, @"one two|\nthree|\nfo|ur", "⌥⌘I puts a caret at the end of each selected line");

    // ⌘D: the word, then its next whole-word occurrences, skipping a longer word
    ed = editor(@"let foo| = foo + food + foo", nil);
    [ed addNextOccurrence:nil];
    SHOWS(ed, @"let [foo|] = foo + food + foo", "⌘D on a caret selects its word");
    [ed addNextOccurrence:nil];
    [ed addNextOccurrence:nil];
    SHOWS(ed, @"let [foo|] = [foo|] + food + [foo|]", "⌘D adds whole-word matches (not food)");
    [ed addNextOccurrence:nil];
    CHECK(ed.cursorCount == 3, "nothing more to add");
    type(ed, @"bar");
    CHECK([text(ed) isEqualToString:@"let bar = bar + food + bar"], "typing renames all: %s", text(ed).UTF8String);
    // starting from a selection matches inside words too, and wraps around
    ed = editor(@"foo food [foo|]", nil);
    [ed addNextOccurrence:nil];
    [ed addNextOccurrence:nil];
    SHOWS(ed, @"[foo|] [foo|]d [foo|]", "⌘D from a selection matches any occurrence, wrapping");
    // ⇧⌘D moves the last one on
    ed = editor(@"[a|] a a", nil);
    [ed addNextOccurrence:nil];
    [ed skipToNextOccurrence:nil];
    SHOWS(ed, @"[a|] a [a|]", "⇧⌘D skips an occurrence");
    // ⇧⌘L
    ed = editor(@"xy xyz xy|", nil);
    [ed selectAllOccurrences:nil];
    SHOWS(ed, @"[xy|] xyz [xy|]", "⇧⌘L selects every whole-word occurrence");
    CHECK(ed->_caret == 9, "the primary stays the one at the caret");

    // ⌥ click adds a cursor, ⌥ click on one removes it
    ed = editor(@"hello\nworld|", nil);
    [ed displayIfNeeded];
    NSPoint at = NSMakePoint(ed.textOriginX + 2.2 * ed->_charWidth, 4 + ed->_lineHeight / 2);
    NSPoint w = [ed convertPoint:at toView:nil];
    NSEvent *click = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:w modifierFlags:NSEventModifierFlagOption
                                       timestamp:0 windowNumber:win.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
    [ed canvasMouseDown:click];
    SHOWS(ed, @"he|llo\nworld|", "⌥ click adds a caret");
    [ed canvasMouseDown:click];
    SHOWS(ed, @"hello\nworld|", "⌥ click on a caret removes it");
    NSEvent *plain = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:w modifierFlags:0
                                       timestamp:0 windowNumber:win.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
    [ed canvasMouseDown:click];
    [ed canvasMouseDown:plain];
    CHECK(ed.cursorCount == 1, "a plain click goes back to one cursor");

    // ⇧⌥ drag: a column; rows shorter than both columns are skipped
    ed = editor(@"abcdef\nab\nabcdef\n", nil);
    [ed displayIfNeeded];
    CGFloat cw = ed->_charWidth, lh = ed->_lineHeight, x0 = ed.textOriginX;
    [ed beginColumnSelectionAt:NSMakePoint(x0 + 3 * cw + 1, 4 + lh / 2)];
    [ed columnSelectTo:NSMakePoint(x0 + 5 * cw + 1, 4 + 2.5 * lh)];
    SHOWS(ed, @"abc[de|]f\nab\nabc[de|]f\n", "column selection");
    type(ed, @"_");
    CHECK([text(ed) isEqualToString:@"abc_f\nab\nabc_f\n"], "typing in a column: %s", text(ed).UTF8String);
    [ed beginColumnSelectionAt:NSMakePoint(x0 + 1 * cw + 1, 4 + lh / 2)];
    [ed columnSelectTo:NSMakePoint(x0 + 1 * cw + 1, 4 + 2.5 * lh)];
    SHOWS(ed, @"a|bc_f\na|b\na|bc_f\n", "a zero-width column is a caret per line");
}

static void clipboard(void) {
    TextEditorView *ed = editor(@"[one|] [two|] [three|]", nil);
    [ed copy:nil];
    CHECK([[pb stringForType:NSPasteboardTypeString] isEqualToString:@"one\ntwo\nthree"], "copy joins the selections by lines");
    ed = editor(@"a| b| c|", nil);
    [ed paste:nil];
    SHOWS(ed, @"aone| btwo| cthree|", "pasting as many pieces as cursors gives one each");
    ed = editor(@"x|", nil);
    [ed paste:nil];
    SHOWS(ed, @"xone\ntwo\nthree|", "one cursor gets all of it");
    // text from elsewhere with one line per cursor is shared out too
    [pb clearContents];
    [pb setString:@"1\n2\n" forType:NSPasteboardTypeString];
    ed = editor(@"|a\n|b", nil);
    [ed paste:nil];
    SHOWS(ed, @"1|a\n2|b", "lines shared out over cursors");

    // nothing selected: whole lines
    ed = editor(@"first\nsec|ond\nthird", nil);
    [ed copy:nil];
    CHECK([[pb stringForType:NSPasteboardTypeString] isEqualToString:@"second\n"], "⌘C without a selection copies the line");
    [ed moveDown:nil];
    [ed paste:nil];
    SHOWS(ed, @"first\nsecond\nsecond\nthi|rd", "and pastes it above the caret's line, the caret staying put");
    ed = editor(@"first\nsec|ond\nthird", nil);
    [ed cut:nil];
    SHOWS(ed, @"first\n|third", "⌘X without a selection cuts the line");
    ed = editor(@"first\nlast|", nil);
    [ed cut:nil];
    SHOWS(ed, @"first|", "cutting the last line takes the break before it");
    [ed paste:nil];
    SHOWS(ed, @"last\nfirst|", "a cut last line pastes as a whole line");
}

#pragma mark Line commands

static void lineCommands(void) {
    TextEditorView *ed = editor(@"one\ntw|o\nthree", nil);
    [ed moveLinesUp:nil];
    SHOWS(ed, @"tw|o\none\nthree", "⌥↑ moves the line up");
    [ed moveLinesUp:nil];
    SHOWS(ed, @"tw|o\none\nthree", "not past the first line");
    [ed moveLinesDown:nil];
    [ed moveLinesDown:nil];
    SHOWS(ed, @"one\nthree\ntw|o", "⌥↓ twice, onto the last line (which has no line break)");
    [ed undo:nil]; [ed undo:nil]; [ed undo:nil];
    SHOWS(ed, @"one\ntw|o\nthree", "each move is one undo step");
    ed = editor(@"[a\nb\n|]c\nd", nil);
    [ed moveLinesDown:nil];
    SHOWS(ed, @"c\n[a\nb\n|]d", "a whole-line selection moves as a block");
    ed = editor(@"|a\n|b\nc", nil);
    [ed moveLinesDown:nil];
    SHOWS(ed, @"c\n|a\n|b", "cursors on touching lines move together");
    ed = editor(@"a\r\nb|\r\nc", nil);
    [ed moveLinesUp:nil];
    CHECK([text(ed) isEqualToString:@"b\r\na\r\nc"], "CRLF line breaks survive a move");

    ed = editor(@"ab|c\nd", nil);
    [ed copyLinesDown:nil];
    SHOWS(ed, @"abc\nab|c\nd", "⇧⌥↓ duplicates the line, the caret on the copy");
    ed = editor(@"ab|c\nd", nil);
    [ed copyLinesUp:nil];
    SHOWS(ed, @"ab|c\nabc\nd", "⇧⌥↑ duplicates it upwards");

    ed = editor(@"abc\nde|f\nxy", nil);
    [ed deleteLines:nil];
    SHOWS(ed, @"abc\nxy|", "⇧⌘K deletes the line; the column carries over as far as the next line goes");
    ed = editor(@"abc\nde|f", nil);
    [ed deleteLines:nil];
    SHOWS(ed, @"ab|c", "deleting the last line");
    ed = editor(@"a|\nb\nc|\nd", nil);
    [ed deleteLines:nil];
    SHOWS(ed, @"b|\nd|", "at two cursors, each keeping its column");

    ed = editor(@"    if (x) {|\n", nil);
    [ed insertLineBelow:nil];
    SHOWS(ed, @"    if (x) {\n        |\n", "⌘↩ opens an indented line after {");
    ed = editor(@"    a|b", nil);
    [ed insertLineAbove:nil];
    SHOWS(ed, @"    |\n    ab", "⇧⌘↩ opens a line above with the same indentation");

    ed = editor(@"[a\nb|]", nil);
    [ed indentLines:nil];
    SHOWS(ed, @"[    a\n    b|]", "⌘] indents the selected lines, which stay selected");
    [ed outdentLines:nil];
    SHOWS(ed, @"[a\nb|]", "⌘[ takes it back");
    ed = editor(@"ab|", nil);
    [ed insertTab:nil];
    SHOWS(ed, @"ab  |", "Tab goes to the next tab stop");

    ed = editor(@"    a|\n\n      b|", @"x.c");
    [ed toggleLineComment:nil];
    SHOWS(ed, @"    // a|\n\n    //   b|", "⌘/ comments at the smallest indentation, past a blank line");
    [ed toggleLineComment:nil];
    SHOWS(ed, @"    a|\n\n      b|", "and uncomments");
    ed = editor(@"x = 1|", @"x.py");
    [ed toggleLineComment:nil];
    CHECK([text(ed) isEqualToString:@"# x = 1"], "Python uses #: %s", text(ed).UTF8String);
    ed = editor(@"a { color: red; }|", @"x.css");
    [ed toggleLineComment:nil];
    CHECK([text(ed) isEqualToString:@"/* a { color: red; } */"], "CSS has block comments only: %s", text(ed).UTF8String);
    [ed toggleLineComment:nil];
    CHECK([text(ed) isEqualToString:@"a { color: red; }"], "and they come off again: %s", text(ed).UTF8String);
    ed = editor(@"<b>x</b>|", @"x.html");
    [ed toggleLineComment:nil];
    CHECK([text(ed) isEqualToString:@"<!-- <b>x</b> -->"], "HTML comments: %s", text(ed).UTF8String);
    ed = editor(@"plain|", @"x.txt");
    [ed toggleLineComment:nil];
    CHECK([text(ed) isEqualToString:@"plain"], "no comments in plain text");

    ed = editor(@"a|  \n    b\nc", nil);
    [ed joinLines:nil];
    SHOWS(ed, @"a| b\nc", "⌃J joins with one space");
    ed = editor(@"[a\n  b\n  c|]", nil);
    [ed joinLines:nil];
    SHOWS(ed, @"[a b c|]", "joining the selected lines");

    ed = editor(@"[b\nc\na\n|]", nil);
    [ed sortLinesAscending:nil];
    CHECK([text(ed) isEqualToString:@"a\nb\nc\n"], "sorting keeps the final line break: %s", text(ed).UTF8String);
    [ed sortLinesDescending:nil];
    CHECK([text(ed) isEqualToString:@"c\nb\na\n"], "descending: %s", text(ed).UTF8String);
    ed = editor(@"item10\nitem9\nitem1|", nil);
    [ed sortLinesAscending:nil];
    CHECK([text(ed) isEqualToString:@"item1\nitem9\nitem10"], "a caret sorts the file, numbers by value: %s", text(ed).UTF8String);

    ed = editor(@"a  \nb\t|\n c ", nil);
    [ed trimTrailingWhitespace:nil];
    SHOWS(ed, @"a\nb|\n c", "trailing spaces and tabs go");

    ed = editor(@"hello wo|rld", nil);
    [ed uppercaseWord:nil];
    SHOWS(ed, @"hello WO|RLD", "upper case of the word at the caret");
    ed = editor(@"[ab|] [cd|]", nil);
    [ed capitalizeWord:nil];
    SHOWS(ed, @"[Ab|] [Cd|]", "case of each selection, kept selected");
}

#pragma mark Typing aids

static void typingAids(void) {
    TextEditorView *ed = editor(@"|", @"x.c");
    type(ed, @"(");
    SHOWS(ed, @"(|)", "( adds )");
    type(ed, @"x");
    SHOWS(ed, @"(x|)", "typing inside");
    type(ed, @")");
    SHOWS(ed, @"(x)|", "typing ) steps over the one auto-close added");
    ed = editor(@"|", @"x.c");
    type(ed, @"[");
    [ed deleteBackward:nil];
    SHOWS(ed, @"|", "backspace removes an empty auto-closed pair");
    ed = editor(@"a = |", @"x.c");
    type(ed, @"\"");
    SHOWS(ed, @"a = \"|\"", "quotes pair after a space");
    ed = editor(@"don|", @"x.c");
    type(ed, @"'");
    SHOWS(ed, @"don'|", "but not inside a word");
    ed = editor(@"|x", @"x.c");
    type(ed, @"(");
    SHOWS(ed, @"(|x", "nor before a word");
    ed = editor(@"x = |", @"x.md");
    type(ed, @"\"(");
    SHOWS(ed, @"x = \"(|)", "Markdown: brackets, no quotes");
    ed = editor(@"|", @"x.txt");
    type(ed, @"(");
    SHOWS(ed, @"(|", "plain text: nothing");
    ed = editor(@"[word|]", @"x.c");
    type(ed, @"(");
    SHOWS(ed, @"([word|])", "a selection gets wrapped and stays selected");
    ed = editor(@"a(|\nb|", @"x.c");
    type(ed, @"{");
    SHOWS(ed, @"a({|}\nb{|}", "at every cursor");
    TextEditorView.autoCloseBrackets = NO;
    ed = editor(@"|", @"x.c");
    type(ed, @"(");
    SHOWS(ed, @"(|", "the setting turns it off");
    TextEditorView.autoCloseBrackets = YES;
    // an explicitly typed ) is not stepped over
    ed = editor(@"|)", @"x.c");
    type(ed, @")");
    SHOWS(ed, @")|)", "a ) that wasn't auto-closed is typed");

    ed = editor(@"    f() {|}", @"x.c");
    [ed insertNewline:nil];
    SHOWS(ed, @"    f() {\n        |\n    }", "Enter between braces opens an indented line");
    ed = editor(@"if x:|", @"x.py");
    [ed insertNewline:nil];
    SHOWS(ed, @"if x:\n    |", "and after a Python colon");
    ed = editor(@"      |x", nil);
    [ed deleteBackward:nil];
    SHOWS(ed, @"    |x", "backspace in the indentation goes back to a tab stop");
    [ed deleteBackward:nil];
    SHOWS(ed, @"|x", "and to the start");

    ed = editor(@"    ab|c", nil);
    [ed moveToLeftEndOfLine:nil];
    SHOWS(ed, @"    |abc", "⌘← goes to the first non-blank character");
    [ed moveToLeftEndOfLine:nil];
    SHOWS(ed, @"|    abc", "then to the start of the line");
    [ed moveToLeftEndOfLine:nil];
    SHOWS(ed, @"    |abc", "and back");
    ed = editor(@"    ab|c", nil);
    [ed moveToBeginningOfParagraph:nil];
    SHOWS(ed, @"|    abc", "⌃A goes to column 0");

    // brackets
    ed = editor(@"f(\")\", x)|", @"x.c");
    [ed updateBracketPair];
    CHECK(ed->_bracketPair[0] == 1 && ed->_bracketPair[1] == 8, "the ) in a string doesn't count (%lu, %lu)",
          (unsigned long)ed->_bracketPair[0], (unsigned long)ed->_bracketPair[1]);
    [ed jumpToBracket:nil];
    CHECK(ed->_caret == 1, "⇧⌘\\ jumps to the matching bracket (%lu)", (unsigned long)ed->_caret);
    ed = editor(@"{\n  // }\n  a|\n}", @"x.c");
    [ed jumpToBracket:nil];
    CHECK(ed->_caret == 0, "and from inside to the enclosing one, past a } in a comment (%lu)", (unsigned long)ed->_caret);
    ed = editor(@"{\n  // }\n}|", @"x.c");
    [ed updateBracketPair];
    CHECK(ed->_bracketPair[0] == 0, "matching across lines skips comments");

    BOOL whole = NO;
    ed = editor(@"foo ba|r baz", nil);
    CHECK([[ed highlightedWord:&whole] isEqualToString:@"bar"] && whole, "the word at the caret is highlighted elsewhere");
    ed = editor(@"foo [ba|]r", nil);
    CHECK([[ed highlightedWord:&whole] isEqualToString:@"ba"] && !whole, "or the selected text");
}

#pragma mark Drawing, wrapping, scale

static void drawing(void) {
    TextEditorView *ed = editor(@"[aaaa|] bbbb\n[cccc|] dddd", nil);
    [ed displayIfNeeded];
    NSBitmapImageRep *rep = [ed bitmapImageRepForCachingDisplayInRect:ed.bounds];
    [ed cacheDisplayInRect:ed.bounds toBitmapImageRep:rep];
    CGFloat sx = rep.pixelsWide / ed.bounds.size.width;
    NSColor *(^at)(CGFloat, CGFloat) = ^NSColor *(CGFloat x, CGFloat y) {
        return [[rep colorAtX:(NSInteger)(x * sx) y:(NSInteger)(y * sx)] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    };
    CGFloat x0 = ed.textOriginX, lh = ed->_lineHeight, cw = ed->_charWidth;
    NSColor *bg = at(x0 + 6 * cw, 4 + 2);
    for (int row = 0; row < 2; row++) {
        NSColor *c = at(x0 + 0.5 * cw, 4 + row * lh + 2);
        CHECK(fabs(c.redComponent - bg.redComponent) + fabs(c.greenComponent - bg.greenComponent) + fabs(c.blueComponent - bg.blueComponent) > 0.05,
              "the selection on row %d is drawn", row);
    }
}

static void wrapFuzz(void) {
    srandom(11);
    NSMutableString *t = [NSMutableString string];
    for (int i = 0; i < 300; i++) [t appendFormat:@"%@\n", [@"" stringByPaddingToLength:(NSUInteger)(random() % 90) withString:@"word " startingAtIndex:0]];
    TextEditorView *ed = editor(t, nil);
    ed.frame = NSMakeRect(0, 0, 360, 400);
    ed.wordWrap = YES;
    [ed displayIfNeeded];
    CHECK(ed.wrapsLines, "wrapping is on");
    NSArray *inserts = @[@"x", @"word word word word word word word word ", @"\n", @"a\nb\n", @""];
    for (int step = 0; step < 150; step++) {
        NSUInteger n = 2 + random() % 6, len = ed->_buf.length;
        NSMutableData *sels = [NSMutableData data];
        for (NSUInteger k = 0; k < n; k++) {
            NSUInteger at = random() % (len + 1), to = MIN(len, at + (random() % 3 ? 0 : random() % 30));
            [sels appendBytes:&(Sel){at, to, -1} length:sizeof(Sel)];
        }
        [ed setCursors:sels.bytes count:n primary:0];
        NSString *ins = inserts[random() % inserts.count];
        if (ins.length) [ed insertText:ins replacementRange:NSMakeRange(NSNotFound, 0)];
        else [ed deleteBackward:nil];
        if (random() % 5 == 0) [ed undo:nil];
        NSUInteger lines = ed->_wrapLines;
        NSData *incremental = [NSData dataWithBytes:ed->_rowStart length:(lines + 1) * sizeof(uint64_t)];
        BOOL valid = ed->_wrapValid;
        ed->_wrapValid = NO;
        [ed ensureWrap];
        NSData *full = [NSData dataWithBytes:ed->_rowStart length:(ed->_wrapLines + 1) * sizeof(uint64_t)];
        if (valid && ![incremental isEqualToData:full]) {
            CHECK(NO, "step %d: the row table after a multi-cursor edit matches a rebuild", step);
            break;
        }
    }
}

static void manyCursors(void) {
    NSMutableString *t = [NSMutableString string];
    for (int i = 0; i < 60000; i++) [t appendString:@"let foo = foo(bar) + 1; // foo\n"];
    TextEditorView *ed = editor([@"|" stringByAppendingString:t], nil);
    ed.wordWrap = YES;
    [ed displayIfNeeded];
    [ed moveWordRight:nil];
    [ed moveWordRight:nil];
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    [ed selectAllOccurrences:nil];
    CFAbsoluteTime t1 = CFAbsoluteTimeGetCurrent();
    CHECK(ed.cursorCount == kMaxCursors, "⇧⌘L stops at %lu cursors (%lu)", (unsigned long)kMaxCursors, (unsigned long)ed.cursorCount);
    type(ed, @"renamed");
    CFAbsoluteTime t2 = CFAbsoluteTimeGetCurrent();
    [ed displayIfNeeded];
    NSString *s = text(ed);
    NSUInteger count = [s componentsSeparatedByString:@"renamed"].count - 1;
    CHECK(count == kMaxCursors, "typed at every cursor (%lu)", (unsigned long)count);
    [ed undo:nil];
    CFAbsoluteTime t3 = CFAbsoluteTimeGetCurrent();
    CHECK([text(ed) isEqualToString:t] && ed.cursorCount == kMaxCursors, "one undo for the whole word at 10 000 cursors");
    [ed moveDown:nil];
    [ed deleteBackward:nil];
    CFAbsoluteTime t4 = CFAbsoluteTimeGetCurrent();
    CHECK(t2 - t1 < 3 && t3 - t2 < 1 && t4 - t3 < 3, "fast enough");
    printf("   10 000 cursors in a 1.9 MB file: select %.2f s, type 7 chars %.2f s, undo %.3f s, move + backspace %.2f s\n",
           t1 - t0, t2 - t1, t3 - t2, t4 - t3);
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 700, 500) styleMask:NSWindowStyleMaskTitled
                                            backing:NSBackingStoreBuffered defer:YES];
        pb = [NSPasteboard pasteboardWithUniqueName];
        multiCursorTyping();
        addingCursors();
        clipboard();
        lineCommands();
        typingAids();
        drawing();
        wrapFuzz();
        manyCursors();
        [pb releaseGlobally];
    }
    if (failures) { printf("%d editing failure(s)\n", failures); return 1; }
    printf("all editing tests passed\n");
    return 0;
}
