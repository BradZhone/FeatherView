// Multiple cursors, line commands and typing aids, on a TextEditorView in an offscreen window.
// Text with cursors is written as markup: "|" is a caret, "[x|]" / "[|x]" a selection (caret at the bar).
#import <Cocoa/Cocoa.h>
#import "TextEditorView+Private.h"
#import "TSession.h"
#import "TerminalPanel.h"
#import "ContentController.h"
#import "TerminalView.h"
#import "VTEscape.h"
#import "FTSplitView.h"
#import "FTTabDrag.h"
#import "TabBarView.h"
#include <signal.h>

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while (0)

static NSWindow *win;
static NSPasteboard *pb;
static void terminals(void);
static void terminalRegressions(void);
static void focusedSplitGroups(NSWindow *window);
static void splits(void);
static void drain(double seconds);
static NSMutableArray<TSession *> *testShells;
static NSMutableArray<ContentController *> *testControllers;
static NSDraggingSession *testDragSession; // nil: source callbacks do not need a native offscreen session.

// Exercise the real destination methods without starting a native drag in an offscreen window.
@interface EditingDragInfo : NSObject <NSDraggingInfo>
@property (nonatomic, strong) NSPasteboard *draggingPasteboard;
@property (nonatomic, weak) NSWindow *draggingDestinationWindow;
@property (nonatomic, strong) id draggingSource;
@property (nonatomic) NSPoint draggingLocation, draggedImageLocation;
@property (nonatomic, strong) NSImage *draggedImage;
@property (nonatomic) NSDragOperation draggingSourceOperationMask;
@property (nonatomic) NSInteger draggingSequenceNumber;
@property NSInteger numberOfValidItemsForDrop;
@property NSDraggingFormation draggingFormation;
@property BOOL animatesToDestination;
@end

@implementation EditingDragInfo
- (void)slideDraggedImageTo:(NSPoint)point { self.draggedImageLocation = point; }
- (NSArray<NSString *> *)namesOfPromisedFilesDroppedAtDestination:(NSURL *)destination { return @[]; }
- (NSSpringLoadingHighlight)springLoadingHighlight { return NSSpringLoadingHighlightNone; }
- (void)resetSpringLoading {}
- (void)enumerateDraggingItemsWithOptions:(NSDraggingItemEnumerationOptions)options forView:(NSView *)view
                                classes:(NSArray<Class> *)classes searchOptions:(NSDictionary<NSPasteboardReadingOptionKey, id> *)searchOptions
                             usingBlock:(void (^)(NSDraggingItem *, NSInteger, BOOL *))block {}
- (void)dealloc { [_draggingPasteboard releaseGlobally]; }
@end

static TSession *trackShell(TSession *session) {
    CHECK(session != nil, "the test shell was created");
    if (session) [testShells addObject:session];
    return session;
}

static ContentController *testController(void) {
    ContentController *cc = [ContentController new];
    cc.alertHandler = ^NSModalResponse(NSAlert *alert) { return NSAlertThirdButtonReturn; };
    [testControllers addObject:cc];
    return cc;
}

static void stopTestShells(void) {
    for (ContentController *cc in testControllers) {
        [cc shutdownTerminals];
        [cc closeAllWithoutAsking];
    }
    // Also cover sessions already closed or accidentally detached by a failed move.
    for (TSession *session in testShells) if (!session.exited) [session terminate];
    CFAbsoluteTime until = CFAbsoluteTimeGetCurrent() + 3;
    while (CFAbsoluteTimeGetCurrent() < until) {
        BOOL live = NO;
        for (TSession *session in testShells) if (!session.exited) live = YES;
        if (!live) break;
        drain(.05);
    }
    for (TSession *session in testShells) if (!session.exited && session.pid > 1) kill(session.pid, SIGKILL);
    until = CFAbsoluteTimeGetCurrent() + 1;
    while (CFAbsoluteTimeGetCurrent() < until) {
        BOOL live = NO;
        for (TSession *session in testShells) if (!session.exited) live = YES;
        if (!live) break;
        drain(.05);
    }
    for (TSession *session in testShells) CHECK(session.exited, "test shell %d exited during cleanup", session.pid);
}

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

#pragma mark Folding and the rest of phase 4

static NSUInteger foldCount(TextEditorView *ed) { return ed->_folds.length / sizeof(Fold); }

static void folding(void) {
    TextEditorView *ed = editor(@"a {|\n    b\n    c\n}\nd", @"x.c");
    CHECK([ed startsRegion:0] && ![ed startsRegion:1] && [ed foldEndOf:0] == 2, "a region from indentation (ends %lu)", (unsigned long)[ed foldEndOf:0]);
    [ed fold:nil];
    CHECK(foldCount(ed) == 1 && ed.rowCount == 3 && [ed lineHidden:1] && [ed lineHidden:2] && ![ed lineHidden:3], "⌥⌘[ folds it (%lu rows)", (unsigned long)ed.rowCount);
    CHECK([ed lineOfRow:1] == 3 && !ed.wrapsLines, "rows skip the hidden lines, and nothing is wrapped");
    [ed displayIfNeeded];
    [ed moveDown:nil];
    CHECK([ed->_buf lineForOffset:ed->_caret] == 3 && foldCount(ed) == 1, "↓ goes past the folded lines");
    // edits elsewhere move the fold along
    [ed moveCaretTo:0 extend:NO];
    [ed insertText:@"z\n" replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK(foldCount(ed) == 1 && ((Fold *)ed->_folds.bytes)->header == 1 && [ed lineHidden:2] && ed.rowCount == 4, "a line added above moves the fold down");
    [ed undo:nil];
    CHECK(foldCount(ed) == 1 && ((Fold *)ed->_folds.bytes)->header == 0 && ed.rowCount == 3, "and undo moves it back");
    [ed moveCaretTo:1 extend:NO];
    type(ed, @"x");
    CHECK(foldCount(ed) == 1 && [text(ed) hasPrefix:@"ax {"], "typing on the folded line keeps the fold (%lu, %s)", (unsigned long)foldCount(ed), text(ed).UTF8String);
    // a caret that goes into the hidden lines unfolds them
    [ed gotoLine:2];
    CHECK(foldCount(ed) == 0 && ed.rowCount == 5, "going to a hidden line unfolds it");
    // a fold whose lines are deleted goes
    ed = editor(@"a {|\n    b\n}\nd", @"x.c");
    [ed fold:nil];
    [ed deleteLines:nil];
    CHECK(foldCount(ed) == 0 && ed.rowCount == ed->_buf.lineCount, "deleting the folded line drops the fold");
    // the caret inside a region folds the region around it, and lands on its first line
    ed = editor(@"a {\n    b\n    c|\n}", @"x.c");
    [ed fold:nil];
    CHECK(foldCount(ed) == 1 && ed->_caret == 3, "folding from inside puts the caret at the end of the first line (%lu)", (unsigned long)ed->_caret);
    [ed unfold:nil];
    CHECK(foldCount(ed) == 0, "⌥⌘] unfolds");

    ed = editor(@"a:|\n  b:\n    c\n  d\ne", @"x.yaml");
    CHECK(ed->_indentWidth == 2, "two-space indentation is detected (%lu)", (unsigned long)ed->_indentWidth);
    [ed foldAll:nil];
    CHECK(foldCount(ed) == 2 && ed.rowCount == 2, "fold all folds the nested regions too (%lu rows)", (unsigned long)ed.rowCount);
    [ed unfold:nil];
    CHECK(foldCount(ed) == 1 && ed.rowCount == 4, "unfolding the outer one keeps the inner one folded (%lu rows)", (unsigned long)ed.rowCount);
    [ed unfoldAll:nil];
    CHECK(foldCount(ed) == 0 && ed.rowCount == 5, "unfold all");

    ed = editor(@"# A|\ntext\n## B\nmore\n\n# C\n```\n# not\n```\n", @"x.md");
    CHECK([ed foldEndOf:0] == 3 && [ed foldEndOf:2] == 3 && [ed foldEndOf:5] == 8, "Markdown folds by heading, not inside code (%lu %lu %lu)",
          (unsigned long)[ed foldEndOf:0], (unsigned long)[ed foldEndOf:2], (unsigned long)[ed foldEndOf:5]);

    // the gutter control
    ed = editor(@"a {|\n    b\n}", @"x.c");
    [ed displayIfNeeded];
    NSPoint at = [ed convertPoint:NSMakePoint(ed.gutterWidth - 9, 4 + ed->_lineHeight / 2) toView:nil];
    NSEvent *click = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:at modifierFlags:0
                                       timestamp:0 windowNumber:win.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
    [ed canvasMouseDown:click];
    CHECK(foldCount(ed) == 1, "clicking the fold control folds");
    NSRect box = [ed foldBoxOfLine:0];
    NSEvent *onBox = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:[ed convertPoint:NSMakePoint(NSMidX(box), NSMidY(box)) toView:nil]
                                   modifierFlags:0 timestamp:0 windowNumber:win.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
    [ed canvasMouseDown:onBox];
    CHECK(foldCount(ed) == 0, "clicking the ⋯ unfolds");

    ed = editor(@"a|\n  b\n", nil);
    [ed moveDown:nil];
    [ed moveToRightEndOfLine:nil];
    [ed insertTab:nil];
    CHECK([text(ed) isEqualToString:@"a\n  b \n"], "Tab goes to the file's two-column stop: %s", text(ed).UTF8String);
}

static void expandSelection(void) {
    TextEditorView *ed = editor(@"x = f(a, \"b|c d\", {y});", @"x.c");
    NSArray *steps = @[@"x = f(a, \"[bc|] d\", {y});", @"x = f(a, \"[bc d|]\", {y});", @"x = f(a, [\"bc d\"|], {y});",
                       @"x = f([a, \"bc d\", {y}|]);", @"x = f[(a, \"bc d\", {y})|];", @"[x = f(a, \"bc d\", {y});|]"];
    for (NSString *want in steps) { [ed expandSelection:nil]; SHOWS(ed, want, "⌃⇧⌘→ step"); }
    for (NSUInteger i = steps.count - 1; i-- > 0;) { [ed shrinkSelection:nil]; SHOWS(ed, steps[i], "⌃⇧⌘← step"); }
    [ed shrinkSelection:nil];
    SHOWS(ed, @"x = f(a, \"b|c d\", {y});", "back to the caret");
}

static void guidesAndWhitespace(void) {
    TextEditorView *ed = editor(@"a\n    x\n        b c|\n", nil);
    TextEditorView.showsIndentGuides = YES;
    TextEditorView.showsWhitespace = YES;
    [ed displayIfNeeded];
    NSBitmapImageRep *rep = [ed bitmapImageRepForCachingDisplayInRect:ed.bounds];
    [ed cacheDisplayInRect:ed.bounds toBitmapImageRep:rep];
    CGFloat sx = rep.pixelsWide / ed.bounds.size.width, x0 = ed.textOriginX, cw = ed->_charWidth, lh = ed->_lineHeight;
    NSColor *(^px)(CGFloat, CGFloat) = ^NSColor *(CGFloat x, CGFloat y) {
        return [[rep colorAtX:(NSInteger)(x * sx) y:(NSInteger)(y * sx)] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    };
    NSColor *bg = px(x0 + 40 * cw, 4 + lh / 2);                  // light or dark, whichever the process draws in
    double (^ink)(CGFloat, CGFloat) = ^double(CGFloat x, CGFloat y) {
        NSColor *c = px(x, y);
        return fabs(c.redComponent - bg.redComponent) + fabs(c.greenComponent - bg.greenComponent) + fabs(c.blueComponent - bg.blueComponent);
    };
    CGFloat row1 = 4 + 2 * lh + lh / 2;            // the line indented twice
    CHECK(ink(floor(x0 + 4 * cw) + 0.5, row1 - lh / 3) > 0.05, "an indent guide at the second level (%.2f)", ink(floor(x0 + 4 * cw) + 0.5, row1 - lh / 3));
    CHECK(ink(x0 + 2.5 * cw, row1) > 0.05, "a dot for a space (%.2f)", ink(x0 + 2.5 * cw, row1));
    TextEditorView.showsWhitespace = NO; TextEditorView.showsIndentGuides = NO;
    ed.needsDisplay = YES; [ed displayIfNeeded]; [ed cacheDisplayInRect:ed.bounds toBitmapImageRep:rep];
    CHECK(ink(floor(x0 + 4 * cw) + 0.5, row1 - lh / 3) < 0.05 && ink(x0 + 2.5 * cw, row1) < 0.05, "both are gone when turned off");
    TextEditorView.showsIndentGuides = YES;
    CHECK(ink(floor(x0 + 4 * cw) + 0.5, 4 + lh / 2) < 0.05, "no guide on a line without indentation (%.2f)", ink(floor(x0 + 4 * cw) + 0.5, 4 + lh / 2));
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
        if (random() % 4 == 0) [ed toggleFoldAtLine:random() % ed->_buf.lineCount];
        if (random() % 9 == 0) [ed unfoldAll:nil];
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
        testShells = [NSMutableArray array];
        testControllers = [NSMutableArray array];
        @try {
            terminalRegressions();
            if (getenv("FEATHER_TERMINAL_VIEW_TESTS_ONLY")) {
                focusedSplitGroups(win);
            } else {
                terminals();
                splits();
            }
            multiCursorTyping();
            addingCursors();
            clipboard();
            lineCommands();
            typingAids();
            drawing();
            folding();
            expandSelection();
            guidesAndWhitespace();
            wrapFuzz();
            manyCursors();
        } @catch (NSException *exception) {
            CHECK(NO, "uncaught %s: %s", exception.name.UTF8String, exception.reason.UTF8String);
        } @finally {
            stopTestShells();
            [pb releaseGlobally];
        }
    }
    if (failures) { printf("%d editing failure(s)\n", failures); return 1; }
    printf("all editing tests passed\n");
    return 0;
}
#pragma mark Terminal

// Implements only the existing session surface: no PTY, subprocess or shared PID registry.
@interface EditingTerminalSession : NSObject
@property (nonatomic, strong) TScreen *screen;
@property (nonatomic, strong) VTEscape *parser;
@property (nonatomic, copy) void (^onChange)(void);
@property (nonatomic, copy) void (^onExit)(void);
@property (nonatomic) NSUInteger resizes;
@property (nonatomic) BOOL exited;
- (void)feed:(NSString *)text;
- (void)resizeCols:(NSUInteger)cols rows:(NSUInteger)rows;
@end
@implementation EditingTerminalSession
- (instancetype)init {
    if ((self = [super init])) {
        _screen = [[TScreen alloc] initWithCols:80 rows:24 scrollback:100];
        _parser = [[VTEscape alloc] initWithEndpoint:_screen];
    }
    return self;
}
- (void)feed:(NSString *)text {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    [_parser feed:data.bytes length:data.length];
    if (_onChange) _onChange();
}
- (void)resizeCols:(NSUInteger)cols rows:(NSUInteger)rows { _resizes++; [_screen resizeCols:cols rows:rows]; }
@end

@interface EditingWheelEvent : NSEvent
@property (nonatomic) CGFloat dx, dy;
@property (nonatomic) BOOL precise;
@property (nonatomic) NSEventModifierFlags flags;
@property (nonatomic) NSWindow *eventWindow;
@property (nonatomic) NSPoint location;
@property (nonatomic) NSTimeInterval stamp;
@end
@implementation EditingWheelEvent
- (CGFloat)scrollingDeltaX { return _dx; }
- (CGFloat)scrollingDeltaY { return _dy; }
- (BOOL)hasPreciseScrollingDeltas { return _precise; }
- (NSEventModifierFlags)modifierFlags { return _flags; }
- (NSWindow *)window { return _eventWindow; }
- (NSPoint)locationInWindow { return _location; }
- (NSTimeInterval)timestamp { return _stamp; }
- (NSEventType)type { return NSEventTypeScrollWheel; }
@end

// Private color helpers are checked alongside rendered pixels, without adding test-only production API.
@interface TerminalView (EditingTestColors)
- (NSColor *)fgOf:(TCell)cell;
- (NSColor *)bgOf:(TCell)cell;
@end

static uint32_t colorRGB(NSColor *color) {
    NSColor *rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return ((uint32_t)round(rgb.redComponent * 255) << 16) | ((uint32_t)round(rgb.greenComponent * 255) << 8) |
           (uint32_t)round(rgb.blueComponent * 255);
}

static NSString *historyText(TScreen *screen, NSUInteger row) {
    NSMutableString *text = [NSMutableString string];
    const TCell *cells = [screen historyCells:row];
    for (NSUInteger col = 0; col < [screen historyLength:row]; col++)
        if (cells[col].ch && cells[col].ch < 128) [text appendFormat:@"%c", (char)cells[col].ch];
    return text;
}

static BOOL screenContains(TScreen *screen, NSString *needle) {
    for (NSUInteger row = 0; row < screen.rows; row++) if ([[screen textOfRow:row] containsString:needle]) return YES;
    for (NSUInteger row = 0; row < screen.historyCount; row++) if ([historyText(screen, row) containsString:needle]) return YES;
    return NO;
}

static void terminalRegressions(void) {
    EditingTerminalSession *model = [EditingTerminalSession new];
    TScreen *s = model.screen;
    CHECK(s.palette[1] == 0xCD0000 && s.palette[0] == 0 && s.palette[15] == 0xFFFFFF,
          "every unmounted screen starts with a deterministic ANSI palette");
    CHECK([s cellAtRow:0 col:0].fg == TCDefault && [s cellAtRow:0 col:0].bg == TCDefault,
          "initial blank cells use the default sentinel");
    [s resizeCols:12 rows:4];
    [model feed:@"one\r\ntwo\r\nthree\r\nfour"];
    [s resizeCols:7 rows:2];
    CHECK(s.historyCount == 2 && [[s textOfRow:0] hasPrefix:@"three"] && [[s textOfRow:1] hasPrefix:@"four"] && s.cursorRow == 1,
          "shrinking keeps the cursor and recent rows and pushes earlier content to history");
    CHECK([historyText(s, 0) isEqualToString:@"one"] && [historyText(s, 1) isEqualToString:@"two"], "resize history remains ordered");
    [s resizeCols:12 rows:4];
    CHECK(s.historyCount == 0 && [[s textOfRow:0] hasPrefix:@"one"] && [[s textOfRow:3] hasPrefix:@"four"] && s.cursorRow == 3,
          "growing restores history and cursor position");
    [s resizeCols:12 rows:8];
    CHECK(s.scrollTop == 0 && s.scrollBottom == 7, "full scroll margins follow a grown screen");
    [model feed:@"\r\nfive\r\nsix\r\nseven\r\neight\r\nnine"];
    CHECK(s.historyCount == 1 && [[s textOfRow:7] hasPrefix:@"nine"], "output after growth uses the entire grid and grows history");
    [s reset];
    [model feed:@"abcdefghij\x1b[8;1Hbottom\x1b[1;1H"];
    [s setScrollRegionTop:2 bottom:6];
    [s resizeCols:4 rows:2];
    CHECK(s.scrollTop <= s.scrollBottom && s.scrollBottom < s.rows && s.historyCount == 0,
          "a custom region stays bounded through a tiny transient size without leaking into history");
    [s scrollUp:3];
    CHECK(s.historyCount == 0, "a clipped custom region never becomes full-screen scrollback");
    [s resizeCols:12 rows:8];
    CHECK(s.scrollTop == 2 && s.scrollBottom == 6 && [[s textOfRow:0] hasPrefix:@"abcdefghij"] && [[s textOfRow:7] hasPrefix:@"bottom"],
          "growing recovers clipped columns, bottom rows and custom margins");
    [s resizeCols:0 rows:0];
    CHECK(s.cols == 12 && s.rows == 8, "zero geometry leaves the screen intact");

    NSView *host = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 700, 500)];
    win.contentView = host;
    NSMutableArray<EditingTerminalSession *> *models = [NSMutableArray array];
    NSMutableArray<TerminalView *> *views = [NSMutableArray array];
    for (NSUInteger i = 0; i < 3; i++) {
        EditingTerminalSession *session = [EditingTerminalSession new];
        TerminalView *view = [[TerminalView alloc] initWithSession:(TSession *)(id)session];
        view.frame = NSMakeRect(0, 0, 540, 220);
        CHECK(session.resizes == 0 && session.screen.cols == 80 && session.screen.rows == 24,
              "unmounted terminal %lu ignores frame geometry", (unsigned long)i);
        [host addSubview:view];
        CHECK(session.resizes == 1 && session.screen.cols > 30 && session.screen.rows > 2,
              "terminal %lu synchronizes on its first usable mount", (unsigned long)i);
        view.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
        [session feed:@"\x1b[31mRED\x1b[32mGREEN\x1b[0m\r\n\x1b[48;2;0;0;0m          \x1b[0m"];
        NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
        [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
        CHECK(session.screen.palette[1] == 0xC13B32 && session.screen.palette[2] == 0x338A22 &&
              session.screen.defaultBg == 0xFFFFFF && session.screen.defaultFg == 0x24292E,
              "light terminal %lu initializes its own ANSI and default colors", (unsigned long)i);
        CGFloat scale = rep.pixelsWide / view.bounds.size.width;
        CGFloat cellH = [[view valueForKey:@"_cellH"] doubleValue];
        CHECK(colorRGB([rep colorAtX:(NSInteger)(12 * scale) y:(NSInteger)((8 + cellH + 4 - view.scrollY) * scale)]) == 0,
              "terminal %lu paints a literal RGB zero background black", (unsigned long)i);
        CHECK(colorRGB([view fgOf:(TCell){'x', 0, TCDefault, 0}]) == 0 &&
              colorRGB([view fgOf:(TCell){'x', TCPal | 16, TCDefault, 0}]) == 0,
              "literal and indexed black foregrounds remain black in terminal %lu", (unsigned long)i);
        [models addObject:session]; [views addObject:view];
    }
    for (NSUInteger i = 0; i < 3; i++) {
        views[i].appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        [views[i] displayIfNeeded];
        NSBitmapImageRep *rep = [views[i] bitmapImageRepForCachingDisplayInRect:views[i].bounds];
        [views[i] cacheDisplayInRect:views[i].bounds toBitmapImageRep:rep];
        CHECK(models[i].screen.palette[1] == 0xE06C60 && models[i].screen.palette[2] == 0x7DBE50 && models[i].screen.defaultBg == 0x1B1E23,
              "dark terminal %lu updates independently", (unsigned long)i);
    }
    views[0].appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    [views[0] viewDidChangeEffectiveAppearance];
    CHECK(models[0].screen.palette[1] == 0xC13B32 && models[1].screen.palette[1] == 0xE06C60,
          "one terminal's appearance does not suppress or alter another terminal's palette");

    TerminalView *view = views[0]; model = models[0]; s = model.screen;
    [host addSubview:view positioned:NSWindowAbove relativeTo:nil];
    [s reset];
    [model feed:@"\x1b[0m"];
    for (NSUInteger i = 0; i < 50; i++) [model feed:[NSString stringWithFormat:@"line-%03lu\r\n", (unsigned long)i]];
    CHECK(view.scrollY > 0 && fabs(view.scrollY - view.maxScrollY) < .5, "fresh terminal follows output past the viewport");
    EditingWheelEvent *wheel = [EditingWheelEvent new]; wheel.precise = YES; wheel.dy = 4;
    [view scrollWheel:wheel];
    CGFloat scrolled = view.scrollY;
    [model feed:@"more\r\n"];
    CHECK(fabs(view.scrollY - scrolled) < .5 && view.scrollY < view.maxScrollY - 4,
          "even a small wheel-up during output stops following without snapping");
    CGFloat cellH = [[view valueForKey:@"_cellH"] doubleValue];
    view.scrollY = 70 * cellH + 3;
    for (NSUInteger i = 0; i < 160; i++) [model feed:[NSString stringWithFormat:@"cap-%03lu\r\n", (unsigned long)i]];
    view.scrollY = 45 * cellH + 3;
    NSString *anchor = historyText(s, (NSUInteger)floor(view.scrollY / cellH));
    NSUInteger origin = s.historyStart;
    CGFloat before = view.scrollY;
    for (NSUInteger i = 0; i < 7; i++) [model feed:@"capped-output\r\n"];
    CHECK(s.historyCount == 100 && s.historyStart == origin + 7 && fabs(view.scrollY - (before - 7 * cellH)) < .5 &&
          [historyText(s, (NSUInteger)floor(view.scrollY / cellH)) isEqualToString:anchor],
          "capped history preserves the exact retained top line and pixel offset");
    before = view.scrollY;
    view.frame = NSMakeRect(0, 0, 610, 270);
    CHECK(fabs(view.scrollY - before) < .5, "a resize preserves a user's history anchor");
    NSUInteger resizes = model.resizes, cols = s.cols, rows = s.rows;
    [view removeFromSuperview];
    view.frame = NSZeroRect;
    [model feed:@"detached-output\r\n"];
    CHECK(model.resizes == resizes && s.cols == cols && s.rows == rows, "detached zero geometry preserves the live grid during output");
    view.frame = NSMakeRect(0, 0, 560, 230);
    [host addSubview:view];
    CHECK(s.scrollBottom == s.rows - 1 && model.resizes > resizes, "reattaching synchronizes geometry and full margins");
    before = view.scrollY;
    [model feed:@"\x1b[?1049hALT\r\nSCREEN"];
    CHECK(view.contentHeight < (s.rows + 1) * cellH && view.scrollY < cellH,
          "alternate-screen geometry excludes primary history");
    NSUInteger history = s.historyCount;
    for (NSUInteger i = 0; i < s.rows + 3; i++) [model feed:@"alternate\r\n"];
    CHECK(s.historyCount == history, "alternate-screen output cannot append primary history");
    [model feed:@"\x1b[?1049l"];
    CHECK(fabs(view.scrollY - before) < .5, "leaving alternate screen restores the primary history anchor");
    view.scrollY = view.maxScrollY;
    [model feed:@"latest-output\r\n"];
    CHECK(fabs(view.scrollY - view.maxScrollY) < .5, "scrolling back to the bottom resumes following");

    NSMutableString *longText = [NSMutableString string];
    for (NSUInteger i = 0; i < 100; i++) [longText appendString:@"a long editor line that can scroll horizontally\n"];
    TextEditorView *ed = editor(longText, @"wheel.txt");
    __block NSUInteger notifications = 0; ed.onScroll = ^{ notifications++; };
    ed.scrollY = 80; notifications = 0;
    wheel.precise = NO; wheel.dy = -2; wheel.dx = 0;
    [ed scrollWheel:wheel];
    CHECK(fabs(ed.scrollY - 112) < .5 && notifications == 1, "editor discrete wheel scaling and single scroll notification are preserved");
    wheel.precise = YES; wheel.dy = 5;
    [ed scrollWheel:wheel];
    CHECK(fabs(ed.scrollY - 107) < .5 && notifications == 2, "editor precise wheel deltas are preserved");
    ed.scrollY = 0; notifications = 0;
    [ed scrollWheel:wheel];
    CHECK(ed.scrollY == 0 && notifications == 0, "clamped editor wheel gestures do not emit false notifications");
}

static void drain(double seconds) {
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

// A shell, a view bound to it, and the panel / tab placement in ContentController.
static void terminals(void) {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    // the view renders output and follows the bottom
    TSession *ts = trackShell([[TSession alloc] initWithDirectory:dir shell:@"/bin/sh" error:nil]);
    if (!ts) return;
    TerminalView *tv = [[TerminalView alloc] initWithSession:ts];
    tv.frame = NSMakeRect(0, 0, 560, 300);
    win.contentView = tv;
    [win makeFirstResponder:tv];
    [ts writeString:@"printf 'term-ok'\n"];
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    while (CFAbsoluteTimeGetCurrent() - t0 < 5 && ![[ts.screen textOfRow:0] containsString:@"term-ok"]) drain(0.05);
    CHECK([[ts.screen textOfRow:0] containsString:@"term-ok"], "the shell echoed through the view");
    [tv displayIfNeeded];
    NSBitmapImageRep *rep = [tv bitmapImageRepForCachingDisplayInRect:tv.bounds];
    [tv cacheDisplayInRect:tv.bounds toBitmapImageRep:rep];
    CGFloat sx = rep.pixelsWide / tv.bounds.size.width;
    NSColor *bg = [[rep colorAtX:(NSInteger)(500 * sx) y:(NSInteger)(rep.pixelsHigh * 0.5)] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    unsigned inked = 0;                        // glyphs anywhere in the upper-left quadrant
    for (NSInteger px = 8; px < 400; px += 12)
        for (NSInteger py = 6; py < 200; py += 10) {
            NSColor *c = [[rep colorAtX:px y:py] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            if (fabs(c.redComponent - bg.redComponent) + fabs(c.greenComponent - bg.greenComponent) + fabs(c.blueComponent - bg.blueComponent) > 0.15) inked++;
        }
    CHECK(inked > 4, "the echoed text is drawn (%u inked samples)", inked);
    // keys: control keys arrive as text commands from the input context; the view encodes them.
    // cat shows what it received: ^[ for an escape, and the termios echo handles the rest.
    [ts writeString:@"cat -v\n"];
    drain(0.3);
    for (NSString *ch in @[@"a", @"b", @"c"]) {
        NSEvent *k = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
                                     timestamp:0 windowNumber:win.windowNumber context:nil characters:ch charactersIgnoringModifiers:ch isARepeat:NO keyCode:0];
        [tv keyDown:k];
    }
    drain(0.2);
    NSUInteger before = [ts.screen cursorRow];
    NSString *row0 = [ts.screen textOfRow:[ts.screen cursorRow]];
    CHECK([row0 containsString:@"abc"], "typing echoes: %s", row0.UTF8String);
    NSEvent *bs = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
                                  timestamp:0 windowNumber:win.windowNumber context:nil characters:@"\x7f" charactersIgnoringModifiers:@"\x7f" isARepeat:NO keyCode:51];
    [tv keyDown:bs];
    drain(0.2);
    row0 = [ts.screen textOfRow:[ts.screen cursorRow]];
    CHECK(([row0 containsString:@"ab"] && ![row0 containsString:@"abc"]), "delete erased a character: %s", row0.UTF8String);
    NSEvent *enter = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
                                     timestamp:0 windowNumber:win.windowNumber context:nil characters:@"\r" charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36];
    [tv keyDown:enter];
    drain(0.2);
    CHECK([ts.screen cursorRow] >= before + 1, "enter moved down (the echo and cat each add a line): %lu → %lu", (unsigned long)before, (unsigned long)[ts.screen cursorRow]);
    [ts writeString:@"xyz\x1b[A\n"];          // an escape sequence typed into cat: it prints ^[A
    drain(0.3);
    __block NSString *all = @"";
    for (NSUInteger r = 0; r < [ts.screen rows]; r++) all = [all stringByAppendingString:[ts.screen textOfRow:r]];
    CHECK([all containsString:@"^[[A"], "the arrow's escape bytes reached cat -v: %s", [all stringByReplacingOccurrencesOfString:@"\n" withString:@"|"].UTF8String);
    [ts writeString:@"\x03"];
    drain(0.2);
    // keys: plain characters go to the shell
    [ts writeString:@"cat > /dev/null\n"];
    drain(0.2);
    NSEvent *x = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
                                 timestamp:0 windowNumber:win.windowNumber context:nil characters:@"x" charactersIgnoringModifiers:@"x" isARepeat:NO keyCode:7];
    [tv keyDown:x];
    drain(0.2);
    CHECK(![ts.screen textOfRow:2].length || YES, "typed into cat without crash");
    [ts writeString:@"\x03"];               // ^C ends cat
    drain(0.2);
    CHECK(ts.screen.cols >= 40 && ts.screen.rows >= 10, "the view resized the PTY (%lux%lu)", (unsigned long)ts.screen.cols, (unsigned long)ts.screen.rows);
    // Real ls colors must survive the PTY and parser as palette-indexed cells.
    NSString *colorDir = [dir stringByAppendingPathComponent:@"ls-colors"];
    NSString *directoryEntry = [colorDir stringByAppendingPathComponent:@"colored-directory"];
    NSString *executable = [colorDir stringByAppendingPathComponent:@"colored-executable"];
    [NSFileManager.defaultManager createDirectoryAtPath:directoryEntry withIntermediateDirectories:YES attributes:nil error:nil];
    [@"#!/bin/sh\nexit 0\n" writeToFile:executable atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0755} ofItemAtPath:executable error:nil];
    [NSFileManager.defaultManager createSymbolicLinkAtPath:[colorDir stringByAppendingPathComponent:@"colored-symlink"] withDestinationPath:@"colored-directory" error:nil];
    [tv clear:nil];
    [ts writeString:[NSString stringWithFormat:@"/bin/ls -G -1 '%@'; printf '\\nls-colors-done\\n'\n", colorDir]];
    t0 = CFAbsoluteTimeGetCurrent();
    BOOL coloredLS = NO;
    while (CFAbsoluteTimeGetCurrent() - t0 < 4) {
        drain(.05);
        NSUInteger colored = 0;
        for (NSUInteger r = 0; r < ts.screen.rows; r++) for (NSUInteger c = 0; c < ts.screen.cols; c++) {
            TCell cell = [ts.screen cellAtRow:r col:c];
            if (cell.ch && cell.fg != TCDefault && (cell.fg & TCPal)) colored++;
        }
        if (colored >= 20) { coloredLS = YES; break; }
    }
    CHECK(coloredLS, "real ls -G directory, symlink and executable output carries ANSI colors through the PTY");
    [tv displayIfNeeded];
    [tv copy:nil];                          // no selection: an interrupt
    [tv clear:nil];
    [tv paste:nil];
    [ts terminate];
    t0 = CFAbsoluteTimeGetCurrent();
    while (!ts.exited && CFAbsoluteTimeGetCurrent() - t0 < 3) drain(0.05);
    CHECK(ts.exited, "terminated");

    // placement: tab and panel keep the same session
    NSWindow *ccWin = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 700, 480) styleMask:NSWindowStyleMaskTitled
                                                  backing:NSBackingStoreBuffered defer:YES];
    ContentController *cc = testController();
    ccWin.contentView = cc.view;
    [ccWin makeKeyAndOrderFront:nil];
    drain(0.1);
    trackShell([cc openTerminalAt:dir asTab:YES]);
    CHECK(cc.tabCount == 1 && cc.activeTerminal != nil && [cc.activeTerminal.directory isEqualToString:dir], "a terminal tab");
    TSession *tabSession = cc.activeTerminal;
    TerminalView *movingView = [[cc valueForKey:@"_terminalViews"] objectForKey:tabSession];
    CHECK([cc.currentTitle containsString:dir.lastPathComponent], "the tab is named after the directory: %s", cc.currentTitle.UTF8String);
    [tabSession writeString:@"printf 'place-'; printf 'before\\n'\n"];
    t0 = CFAbsoluteTimeGetCurrent();
    while (CFAbsoluteTimeGetCurrent() - t0 < 4 && !screenContains(tabSession.screen, @"place-before")) drain(.05);
    CHECK(screenContains(tabSession.screen, @"place-before"), "the terminal produces parsed output before a placement move");
    [cc moveActiveTerminalToPanel];
    CHECK(cc.tabCount == 0 && cc.terminalPanelVisible && cc.activeTerminal == tabSession, "moved to the panel, the session survived");
    CHECK([[cc valueForKey:@"_terminalPanel"] currentView] == movingView, "panel placement reuses the terminal attachment");
    [tabSession writeString:@"printf 'place-'; printf 'panel\\n'\n"];
    t0 = CFAbsoluteTimeGetCurrent();
    while (CFAbsoluteTimeGetCurrent() - t0 < 4 && !screenContains(tabSession.screen, @"place-panel")) drain(.05);
    CHECK(screenContains(tabSession.screen, @"place-panel"), "the terminal keeps producing output after moving to the panel");
    [cc moveActivePanelTerminalToTab];
    CHECK(cc.tabCount == 1 && cc.activeTerminal == tabSession && !cc.terminalPanelVisible, "back to a tab");
    CHECK([[cc valueForKey:@"_terminalViews"] objectForKey:tabSession] == movingView && movingView.window == ccWin,
          "tab placement preserves and mounts the original attachment");
    [tabSession writeString:@"printf 'place-'; printf 'tab\\n'\n"];
    t0 = CFAbsoluteTimeGetCurrent();
    while (CFAbsoluteTimeGetCurrent() - t0 < 4 && !screenContains(tabSession.screen, @"place-tab")) drain(.05);
    CHECK(screenContains(tabSession.screen, @"place-tab") && tabSession.screen.scrollBottom == tabSession.screen.rows - 1,
          "output and full-screen scrolling continue after panel-to-tab resize");
    trackShell([cc openTerminalAt:nil asTab:NO]);
    CHECK(cc.terminalCount == 2 && cc.terminalPanelVisible, "a second terminal in the panel");
    // the panel strip: a ✕ per terminal, closes without prompting
    NSView *panel = nil;
    for (NSView *v in cc.view.subviews) if ([v isKindOfClass:TerminalPanel.class]) panel = v;
    CHECK(panel != nil && [((TerminalPanel *)panel) tabCount] == 1, "the panel shows its terminal (%lu)", (unsigned long)[((TerminalPanel *)panel) tabCount]);
    [(TerminalPanel *)panel closeTabAtIndex:0];
    CHECK(cc.terminalCount == 1 && !cc.terminalPanelVisible, "the ✕ closed its terminal; an empty panel hides itself (t %lu, panel %d)",
          (unsigned long)cc.terminalCount, (int)cc.terminalPanelVisible);
    // drag & drop between the tab bar and the panel: a token round-trips to the session
    NSString *token = [TSession registerDragSession:tabSession];
    CHECK([TSession sessionForDragToken:token] == tabSession, "the drag token maps back to the session");
    [cc moveTerminalToTab:tabSession];                       // already a tab: just activates it
    CHECK(cc.tabCount == 1 && cc.activeTerminal == tabSession, "dropping a terminal on the tab bar keeps it");
    NSButton *tbtn = [cc valueForKeyPath:@"_statusBar.terminalButton"];
    CHECK(tbtn && tbtn.frame.size.width > 0, "the status bar has a terminal button");
    // a new terminal starts in the workspace (the provider), not in the home directory
    cc.terminalDirectoryProvider = ^NSString * { return @"/private/tmp"; };
    TSession *prov = trackShell([cc openTerminalAt:nil asTab:NO]);
    CHECK([prov.directory isEqualToString:@"/private/tmp"], "new terminals follow the workspace provider: %s", prov.directory.UTF8String);
    cc.terminalDirectoryProvider = nil;
    cc.alertHandler = ^NSModalResponse(NSAlert *a) { return NSAlertFirstButtonReturn; };
    [cc closeTerminal:prov];
    CHECK(cc.terminalCount == 1, "cleaned up the provider terminal");
    // a pathless tab survives the saved session and the external-change check
    NSDictionary *st = [cc sessionState];
    CHECK([st[@"tabs"] count] == 0, "terminals are not in the saved session");
    [cc checkExternalChanges];
    CHECK(cc.tabCount == 1 && cc.activeTerminal == tabSession, "no crash from a pathless tab");
    [cc closeTerminal:tabSession];
    CHECK(cc.terminalCount == 0 && cc.tabCount == 0, "all gone (t %lu, tabs %lu, exited %d)", (unsigned long)cc.terminalCount, (unsigned long)cc.tabCount, (int)tabSession.exited);
    [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
}

#pragma mark Split view

static NSEvent *mouse(NSEventType type, NSWindow *w, NSPoint p, NSInteger clicks) {
    return [NSEvent mouseEventWithType:type location:p modifierFlags:0 timestamp:0 windowNumber:w.windowNumber
                               context:nil eventNumber:0 clickCount:clicks pressure:1];
}

static EditingDragInfo *dragInfo(NSString *token, NSString *type, TabBarView *source, NSView *target, NSPoint point) {
    EditingDragInfo *info = [EditingDragInfo new];
    info.draggingPasteboard = [NSPasteboard pasteboardWithUniqueName];
    if (token.length) [info.draggingPasteboard setString:token forType:type];
    info.draggingSource = source;
    info.draggingDestinationWindow = target.window;
    info.draggingLocation = [target convertPoint:point toView:nil];
    info.draggingSourceOperationMask = NSDragOperationMove;
    return info;
}

static NSString *dragToken(TabBarView *bar, NSInteger index, BOOL terminal) {
    CHECK(bar.tabDragTokenForIndex != nil && bar.canDropTab != nil && bar.onDropTab != nil,
          "the tab bar has generic drag/drop callbacks");
    NSString *token = bar.tabDragTokenForIndex ? bar.tabDragTokenForIndex(index) : nil;
    NSString *type = bar.tabDragTypeForIndex ? bar.tabDragTypeForIndex(index) : bar.tabDragType;
    CHECK(token.length && [type isEqualToString:terminal ? FTTerminalDragType : FTTabDragType],
          "the source callback supplies a token and the correct pasteboard type");
    CHECK(terminal ? [TSession sessionForDragToken:token] != nil : [FTTabDrag objectForToken:token] != nil,
          "the source token resolves in its registry");
    return token;
}

static BOOL dropContent(TabBarView *source, NSInteger index, BOOL terminal, NSView *target, FTTabDropZone zone, BOOL accepted) {
    CHECK([target isKindOfClass:FTTabDropView.class], "every column host inherits FTTabDropView");
    if (![target isKindOfClass:FTTabDropView.class]) return NO;
    FTTabDropView *host = (FTTabDropView *)target;
    NSString *token = dragToken(source, index, terminal);
    NSRect bounds = host.bounds;
    NSPoint point = NSMakePoint(zone == FTTabDropBefore ? NSMinX(bounds) + 12 :
                               zone == FTTabDropAfter ? NSMaxX(bounds) - 12 : NSMidX(bounds),
                               NSMinY(bounds) + 30 + (bounds.size.height - 30) / 2);
    CHECK([host dropZoneForPoint:point] == zone, "the content point selects drop zone %ld", (long)zone);
    EditingDragInfo *info = dragInfo(token, terminal ? FTTerminalDragType : FTTabDragType, source, host, point);
    NSDragOperation operation = accepted ? NSDragOperationMove : NSDragOperationNone;
    CHECK([host draggingEntered:info] == operation, "content draggingEntered validates the drop");
    CHECK([host draggingUpdated:info] == operation, "content draggingUpdated validates the drop");
    CHECK([host prepareForDragOperation:info] == accepted, "content prepare validates the drop");
    BOOL result = [host performDragOperation:info];
    CHECK(result == accepted, "content performDragOperation expected %d, got %d", accepted, result);
    [host concludeDragOperation:info];
    [source draggingSession:testDragSession endedAtPoint:NSZeroPoint operation:result ? NSDragOperationMove : NSDragOperationNone];
    if (!terminal) [FTTabDrag forgetToken:token];
    return result;
}

static void dropInBar(TabBarView *source, NSInteger index, BOOL terminal, TabBarView *target, NSInteger insertion) {
    NSString *token = dragToken(source, index, terminal);
    CHECK(target.canDropTab && target.canDropTab(token, terminal), "the target tab bar accepts an existing tab");
    // These tests insert before the first visible tab or append after the last tab.
    if (target.onSelect && target.items.count) target.onSelect(insertion == 0 ? 0 : (NSInteger)target.items.count - 1);
    NSRect tab = [target rectForTab:insertion == 0 ? 0 : (NSInteger)target.items.count - 1];
    NSPoint point = NSMakePoint(insertion == 0 ? MAX(1, NSMinX(tab) + 1) : MIN(NSMaxX(target.bounds) - 1, NSMaxX(tab) - 1), NSMidY(target.bounds));
    EditingDragInfo *info = dragInfo(token, terminal ? FTTerminalDragType : FTTabDragType, source, target, point);
    CHECK([target draggingEntered:info] == NSDragOperationMove && [target prepareForDragOperation:info], "tab strip prepares an Into drop");
    CHECK([target performDragOperation:info], "tab strip performs an Into drop at insertion %ld", (long)insertion);
    [target concludeDragOperation:info];
    [source draggingSession:testDragSession endedAtPoint:NSZeroPoint operation:NSDragOperationMove];
    if (!terminal) [FTTabDrag forgetToken:token];
}

static void tabDragLifecycle(TabBarView *bar) {
    CHECK([bar draggingSession:testDragSession sourceOperationMaskForDraggingContext:NSDraggingContextWithinApplication] == NSDragOperationMove,
          "tab drags within the application are MOVE");
    CHECK([bar draggingSession:testDragSession sourceOperationMaskForDraggingContext:NSDraggingContextOutsideApplication] == NSDragOperationNone,
          "tab drags cannot detach outside the application");
    CHECK([bar ignoreModifierKeysForDraggingSession:testDragSession], "modifier keys cannot turn a move into a copy");
    if (!bar.items.count) return;
    if (bar.onSelect) bar.onSelect(0);
    NSRect tab = [bar rectForTab:0];
    NSPoint point = [bar convertPoint:NSMakePoint(MAX(2, NSMinX(tab) + 12), NSMidY(tab)) toView:nil];
    [bar mouseDown:mouse(NSEventTypeLeftMouseDown, bar.window, point, 1)];
    CHECK([[bar valueForKey:@"_dragIndex"] integerValue] == 0 && [bar valueForKey:@"_downEvent"] != nil,
          "mouse down arms the source tab");
    // Seed an in-flight state without invoking beginDraggingSessionWithItems: offscreen.
    [bar setValue:@YES forKey:@"_dragging"];
    [bar setValue:@YES forKey:@"_nativeDrag"];
    [bar setValue:@1 forKey:@"_dropIndex"];
    [bar draggingSession:testDragSession endedAtPoint:point operation:NSDragOperationNone];
    CHECK([[bar valueForKey:@"_dragIndex"] integerValue] == -1 && [[bar valueForKey:@"_pressClose"] integerValue] == -1 &&
          ![[bar valueForKey:@"_dragging"] boolValue] && ![[bar valueForKey:@"_nativeDrag"] boolValue] &&
          [bar valueForKey:@"_downEvent"] == nil && [[bar valueForKey:@"_dropIndex"] integerValue] == -1,
          "drag ended resets press, native drag, event, and insertion highlight state");
}


static void invalidDropTokens(TabBarView *bar, FTTabDropView *host, BOOL terminal) {
    NSObject *object = [NSObject new];
    NSString *token = [FTTabDrag registerObject:object];
    CHECK([FTTabDrag objectForToken:token] == object, "generic registry preserves identity");
    [FTTabDrag forgetToken:token];
    CHECK([FTTabDrag objectForToken:token] == nil && [FTTabDrag objectForToken:@""] == nil &&
          [FTTabDrag objectForToken:@"invalid-token"] == nil, "forgotten, empty, and unknown tokens are rejected by the registry");
    for (NSString *bad in @[token, @"invalid-token", @""]) {
        CHECK(bar.canDropTab && !bar.canDropTab(bad, terminal), "tab callback rejects an invalid token");
        CHECK(bar.onDropTab && !bar.onDropTab(bad, terminal, 0), "tab callback cannot perform an invalid token drop");
        EditingDragInfo *info = dragInfo(bad, terminal ? FTTerminalDragType : FTTabDragType, bar, host,
                                        NSMakePoint(NSMidX(host.bounds), NSMidY(host.bounds)));
        CHECK([host draggingEntered:info] == NSDragOperationNone && ![host prepareForDragOperation:info] && ![host performDragOperation:info],
              "content destination rejects invalid pasteboard tokens");
        [host draggingEnded:info];
    }
    NSString *wrongClass = [FTTabDrag registerObject:object];
    CHECK(!bar.canDropTab(wrongClass, NO) && ![host acceptToken:wrongClass terminal:NO zone:FTTabDropInto index:0],
          "a registered object of the wrong class cannot be dropped as a tab");
    [FTTabDrag forgetToken:wrongClass];
}

// Hit testing starts at the window root. NSView hitTest: takes its parent's coordinates.
static NSView *rootHit(NSWindow *window, NSPoint windowPoint) {
    NSView *root = window.contentView;
    NSPoint point = [root convertPoint:windowPoint fromView:nil];
    if (root.superview) point = [root convertPoint:point toView:root.superview];
    return [root hitTest:point];
}

static void dividerDrag(NSWindow *window, FTSplitView *split, const char *name) {
    if (split.items.count < 2) { CHECK(NO, "%s needs two columns", name); return; }
    split.maximized = NO;
    split.focused = 0;
    NSRect original = split.frame;
    split.frame = NSMakeRect(original.origin.x + 23, original.origin.y + 17,
                            original.size.width - 46, original.size.height - 34);
    // Start the first boundary with room to move left even if the application auto-focused a neighbour.
    NSView *first = split.items[0];
    CGFloat minimum = MIN(split.minimumItemWidth, split.bounds.size.width / split.items.count);
    first.frame = NSMakeRect(0, 0, split.bounds.size.width - (split.items.count - 1) * minimum, split.bounds.size.height);
    CGFloat startX = NSMaxX(first.frame);
    for (NSUInteger i = 1; i < split.items.count; i++) {
        split.items[i].frame = NSMakeRect(startX, 0, minimum, split.bounds.size.height);
        startX += minimum;
    }
    NSPoint origin = [split convertPoint:NSZeroPoint toView:nil];
    CHECK(split.frame.origin.x != 0 && split.frame.origin.y != 0 && origin.x != 0 && origin.y != 0,
          "%s tests a split with nonzero local and window origins", name);
    CGFloat boundary = NSMaxX(split.items[0].frame), y = MIN(70, NSMidY(split.bounds));
    for (NSNumber *offset in @[@(-7), @0, @7]) {
        NSPoint point = [split convertPoint:NSMakePoint(boundary + offset.doubleValue, y) toView:nil];
        CHECK(rootHit(window, point) == split, "%s root hit test selects FTSplitView at divider offset %.0f", name, offset.doubleValue);
    }
    NSPoint away = [split convertPoint:NSMakePoint(boundary + 18, y) toView:nil];
    CHECK(rootHit(window, away) != split, "%s gives content outside the divider band to child views", name);
    NSPoint start = [split convertPoint:NSMakePoint(boundary + 6, y) toView:nil];
    NSView *receiver = rootHit(window, start);
    CHECK(receiver == split, "%s routes the divider gesture to FTSplitView", name);
    if (receiver == split) {
        CGFloat before = split.items[0].frame.size.width;
        CGFloat desired = MAX(MIN(split.minimumItemWidth, split.bounds.size.width / split.items.count), before - 90);
        NSPoint end = [split convertPoint:NSMakePoint(desired, y) toView:nil];
        [receiver mouseDown:mouse(NSEventTypeLeftMouseDown, window, start, 1)];
        [receiver mouseDragged:mouse(NSEventTypeLeftMouseDragged, window, end, 1)];
        [receiver mouseUp:mouse(NSEventTypeLeftMouseUp, window, end, 1)];
        CHECK(fabs(split.items[0].frame.size.width - desired) <= 2 && desired < before - 20,
              "%s routed drag resizes the first column (%.0f -> %.0f, expected %.0f)", name, before, split.items[0].frame.size.width, desired);
        CGFloat total = 0;
        for (NSView *item in split.items) total += item.frame.size.width;
        CHECK(fabs(total - split.bounds.size.width) <= 2, "%s routed drag preserves the total width", name);
        [receiver mouseDragged:mouse(NSEventTypeLeftMouseDragged, window, start, 1)];
        CHECK(fabs(split.items[0].frame.size.width - desired) <= 2, "%s mouse up ends the divider drag", name);
    }
    split.frame = original;
    [split applyLayout];
}

static void doubleClickTab(NSWindow *window, TabBarView *bar, NSInteger index) {
    NSRect tab = [bar rectForTab:index];
    NSPoint point = [bar convertPoint:NSMakePoint(NSMinX(tab) + 14, NSMidY(tab)) toView:nil];
    NSView *receiver = rootHit(window, point);
    CHECK(receiver == bar, "the root routes a tab double-click to its tab bar");
    if (receiver != bar) return;
    [receiver mouseDown:mouse(NSEventTypeLeftMouseDown, window, point, 1)];
    [receiver mouseUp:mouse(NSEventTypeLeftMouseUp, window, point, 1)];
    [receiver mouseDown:mouse(NSEventTypeLeftMouseDown, window, point, 2)];
    [receiver mouseUp:mouse(NSEventTypeLeftMouseUp, window, point, 2)];
}

static void focusedSplitGroups(NSWindow *window) {
    FTSplitView *split = [[FTSplitView alloc] initWithFrame:NSMakeRect(20, 20, 900, 240)];
    NSView *a = [NSView new], *b = [NSView new], *c = [NSView new];
    [window.contentView addSubview:split];
    split.items = @[a, b, c];
    CHECK(!split.isMaximized && split.minimumItemWidth == 180,
          "new split groups retain ordinary widths by default");
    for (NSInteger focus = 0; focus < 3; focus++) {
        split.focused = focus;
        for (NSView *item in split.items)
            CHECK(fabs(item.frame.size.width - 300) <= 1, "focus alone never enables group expansion");
    }
    split.maximized = YES;
    for (NSInteger focus = 0; focus < 3; focus++) {
        split.focused = focus;
        CGFloat x = 0;
        for (NSInteger i = 0; i < 3; i++) {
            CHECK(fabs(split.items[i].frame.origin.x - x) <= 1 &&
                  fabs(split.items[i].frame.size.width - (i == focus ? 540 : 180)) <= 1,
                  "focus %ld expands the correct group without changing group order", (long)focus);
            x = NSMaxX(split.items[i].frame);
        }
    }
    split.frame = NSMakeRect(20, 20, 420, 240);
    for (NSView *item in split.items) CHECK(fabs(item.frame.size.width - 140) <= 1, "narrow windows share all available group width");
    split.frame = NSMakeRect(20, 20, 900, 240);
    split.maximized = NO;
    NSArray<NSNumber *> *weights = split.weights;
    NSArray<NSValue *> *frames = @[[NSValue valueWithRect:a.frame], [NSValue valueWithRect:b.frame], [NSValue valueWithRect:c.frame]];
    split.maximized = YES;
    split.maximized = NO;
    CHECK([split.weights isEqualToArray:weights] && NSEqualRects(a.frame, frames[0].rectValue) &&
          NSEqualRects(b.frame, frames[1].rectValue) && NSEqualRects(c.frame, frames[2].rectValue),
          "explicit maximize toggles restore manual proportions");
    split.focused = 0;
    split.maximized = YES;
    NSPoint start = [split convertPoint:NSMakePoint(NSMaxX(a.frame), 80) toView:nil];
    NSPoint end = [split convertPoint:NSMakePoint(440, 80) toView:nil];
    [split mouseDown:mouse(NSEventTypeLeftMouseDown, window, start, 1)];
    [split mouseDragged:mouse(NSEventTypeLeftMouseDragged, window, end, 1)];
    [split mouseUp:mouse(NSEventTypeLeftMouseUp, window, end, 1)];
    CHECK(!split.isMaximized && fabs(a.frame.size.width - 440) <= 1, "manual divider drag retains its chosen width");
    split.focused = 0; [split applyLayout]; [split applyLayout];
    CHECK(fabs(a.frame.size.width - 440) <= 1, "repeated layout and same-group focus preserve a manual drag");
    split.focused = 2;
    CHECK(!split.isMaximized && fabs(c.frame.size.width - 180) <= 1 && fabs(a.frame.size.width - 440) <= 1,
          "focusing a minimum-width group after a manual drag preserves the chosen widths");
    split.maximized = YES;
    split.items = @[a];
    split.items = @[a, b];
    CHECK(!split.isMaximized, "single-to-multiple groups keep expansion disabled");
    [split removeFromSuperview];
}

static NSArray<TabBarView *> *editorBars(ContentController *cc) { return [[cc valueForKey:@"_tabBars"] copy]; }

static BOOL tabIsPreview(ContentController *cc, NSString *path) {
    for (id doc in [cc valueForKey:@"_docs"])
        if ([[doc valueForKey:@"path"] isEqualToString:path]) return [[doc valueForKey:@"preview"] boolValue];
    return NO;
}

// ⌘ + wheel resizes whatever the zoom shortcuts act on; a plain wheel must still scroll.
static void commandWheelZoom(ContentController *cc, NSWindow *window, NSString *path) {
    [cc closeAllWithoutAsking];
    [cc openPath:path preview:NO focus:YES];
    [window.contentView layoutSubtreeIfNeeded];
    TextEditorView *ed = cc.editor;
    CHECK(ed != nil && cc.canZoom, "the editor is the zoom target before a wheel gesture");
    if (!ed) return;

    EditingWheelEvent *wheel = [EditingWheelEvent new];
    wheel.eventWindow = window;
    wheel.precise = YES;
    wheel.location = [ed convertPoint:NSMakePoint(NSMidX(ed.bounds), NSMidY(ed.bounds)) toView:nil];
    // One continuous gesture: AppKit delivers its deltas about 10 ms apart.
    __block NSTimeInterval stamp = 100;
    BOOL (^spin)(CGFloat) = ^BOOL(CGFloat dy) {
        wheel.dy = dy;
        stamp += 0.01;
        wheel.stamp = stamp;
        return [cc zoomByScrollWheel:wheel];
    };

    CGFloat size = TextEditorView.defaultFontSize;
    wheel.flags = 0;
    CHECK(!spin(40) && TextEditorView.defaultFontSize == size, "a wheel without ⌘ is left to scroll the view");
    wheel.flags = NSEventModifierFlagOption;
    CHECK(!spin(40) && TextEditorView.defaultFontSize == size, "⌥ + wheel is not a zoom gesture");

    // One step per accumulated notch, not one per delta: a trackpad sends many small deltas.
    wheel.flags = NSEventModifierFlagCommand;
    CHECK(spin(6) && TextEditorView.defaultFontSize == size,
          "⌘ + wheel consumes a partial delta without a font step (%.0f)", TextEditorView.defaultFontSize);
    spin(6);
    spin(6);
    CHECK(TextEditorView.defaultFontSize == size + 1, "accumulated ⌘ + wheel up grows the font once (%.0f -> %.0f)",
          size, TextEditorView.defaultFontSize);
    CHECK(ed.fontSize == TextEditorView.defaultFontSize, "the open editor follows the new default size");

    // A direction change starts over instead of cancelling against the leftover delta.
    spin(-18);
    CHECK(TextEditorView.defaultFontSize == size, "⌘ + wheel down shrinks the font back (%.0f)", TextEditorView.defaultFontSize);
    spin(-18 * 4);
    CHECK(TextEditorView.defaultFontSize == size - 4, "a fast gesture spends every whole step (%.0f)", TextEditorView.defaultFontSize);
    spin(18 * 4);
    CHECK(TextEditorView.defaultFontSize == size, "the font returns to its starting size (%.0f)", TextEditorView.defaultFontSize);

    // A pause ends the gesture, so a later nudge cannot inherit its leftover delta.
    spin(12);
    stamp += 1;
    spin(12);
    CHECK(TextEditorView.defaultFontSize == size, "a paused gesture does not carry its delta over (%.0f)", TextEditorView.defaultFontSize);

    // Discrete mouse wheels report whole notches, which must step immediately.
    stamp += 1;
    wheel.precise = NO;
    spin(1);
    CHECK(TextEditorView.defaultFontSize == size + 1, "one notch of a discrete wheel is one font step (%.0f)",
          TextEditorView.defaultFontSize);
    spin(-1);
    CHECK(TextEditorView.defaultFontSize == size, "a discrete notch down steps back (%.0f)", TextEditorView.defaultFontSize);
    wheel.precise = YES;

    // Outside the content area (the sidebar, the title bar) the gesture is none of our business.
    wheel.location = NSMakePoint(-50, NSMidY(cc.view.bounds));
    CHECK(!spin(18 * 3) && TextEditorView.defaultFontSize == size,
          "⌘ + wheel outside the content area changes nothing (%.0f)", TextEditorView.defaultFontSize);

    // The terminal is its own zoom target and keeps its own size.
    stamp += 1;
    TSession *session = [cc openTerminalAt:nil asTab:YES];
    if (session) [testShells addObject:session];
    [window.contentView layoutSubtreeIfNeeded];
    TerminalView *tv = [[cc valueForKey:@"_terminalViews"] objectForKey:session];
    CHECK(tv != nil && tv.window == window, "a terminal tab is open for the wheel gesture");
    if (tv) {
        CGFloat terminalSize = tv.fontSize;
        wheel.location = [tv convertPoint:NSMakePoint(NSMidX(tv.bounds), NSMidY(tv.bounds)) toView:nil];
        CHECK(spin(18) && tv.fontSize == terminalSize + 1, "⌘ + wheel grows the terminal font (%.0f -> %.0f)",
              terminalSize, tv.fontSize);
        CHECK(TextEditorView.defaultFontSize == size, "zooming a terminal leaves the editor font alone (%.0f)",
              TextEditorView.defaultFontSize);
        stamp += 1;
        spin(-18);
        CHECK(tv.fontSize == terminalSize, "⌘ + wheel shrinks the terminal font back (%.0f)", tv.fontSize);
    }
    [cc closeAllWithoutAsking];
}

// Double-clicking a preview tab must spend the first gesture on pinning it, not on resizing the
// workspace: expansion only toggles once the tab is already kept open.
static void previewTabDoubleClick(ContentController *cc, NSWindow *window, FTSplitView *split, NSString *path) {
    CHECK(cc.paneCount > 1 && !split.isMaximized, "preview double-click starts with several columns and no expansion");
    NSInteger pane = 0;
    [cc focusPane:pane];
    [cc openPath:path preview:YES focus:YES];
    CHECK(tabIsPreview(cc, path) && [cc.currentPath isEqualToString:path], "the file opens as a preview tab");
    NSArray<NSNumber *> *widths = split.weights;
    NSInteger index = -1, seen = 0;
    for (id doc in [cc valueForKey:@"_docs"]) {
        if ([[doc valueForKey:@"pane"] integerValue] != pane) continue;
        if ([[doc valueForKey:@"path"] isEqualToString:path]) { index = seen; break; }
        seen++;
    }
    CHECK(index >= 0, "the preview tab has a position in its own column");
    if (index < 0) return;

    doubleClickTab(window, editorBars(cc)[pane], index);
    CHECK(!tabIsPreview(cc, path), "the first double-click keeps a preview tab open");
    CHECK(!split.isMaximized && [split.weights isEqualToArray:widths],
          "pinning a preview tab leaves column widths untouched");
    doubleClickTab(window, editorBars(cc)[pane], index);
    CHECK(split.isMaximized, "the second double-click expands the focused column");
    doubleClickTab(window, editorBars(cc)[pane], index);
    CHECK(!split.isMaximized && [split.weights isEqualToArray:widths],
          "a pinned tab keeps toggling expansion on every later double-click");
    [cc closeActive];
}

static NSArray<NSString *> *pathsInPane(ContentController *cc, NSUInteger pane) {
    NSMutableArray *paths = [NSMutableArray array];
    for (id doc in [cc valueForKey:@"_docs"])
        if ([[doc valueForKey:@"pane"] unsignedIntegerValue] == pane) [paths addObject:[doc valueForKey:@"path"] ?: @""];
    return paths;
}

static void editorDrops(ContentController *cc, NSWindow *window, NSArray<NSString *> *paths) {
    [cc closeAllWithoutAsking];
    cc.autoSaveMode = AutoSaveOff;
    for (NSString *path in paths) [cc openPath:path preview:NO focus:YES];
    FTSplitView *split = [cc valueForKey:@"_split"];
    NSArray *docs = [[cc valueForKey:@"_docs"] copy];
    [cc openPath:paths[0] preview:NO focus:YES];
    TextEditorView *original = cc.editor;
    type(original, @"kept-");
    NSString *edited = text(original);
    tabDragLifecycle(editorBars(cc)[0]);
    invalidDropTokens(editorBars(cc)[0], (FTTabDropView *)split.items[0], NO);

    TabBarView *bar = editorBars(cc)[0];
    NSString *token = dragToken(bar, 0, NO);
    CHECK(bar.canDropTab(token, NO) && bar.onDropTab(token, NO, 4), "same-bar callback reorders a tab using a pre-removal insertion index");
    [FTTabDrag forgetToken:token];
    CHECK(([pathsInPane(cc, 0) isEqualToArray:@[paths[1], paths[2], paths[3], paths[0]]]), "same-bar reorder preserves all four editor tabs");
    dropInBar(editorBars(cc)[0], 3, NO, editorBars(cc)[0], 0);
    CHECK([pathsInPane(cc, 0) isEqualToArray:paths], "tab-strip destination reorders the last editor tab to the start");

    if (!dropContent(editorBars(cc)[0], 1, NO, split.items[0], FTTabDropAfter, YES)) return;
    CHECK(cc.paneCount == 2 && cc.tabCount == 4 && [pathsInPane(cc, 1) isEqualToArray:@[paths[1]]], "right body drop splits out the existing editor tab");
    if (!dropContent(editorBars(cc)[0], 1, NO, split.items[0], FTTabDropBefore, YES)) return;
    CHECK(cc.paneCount == 3 && cc.tabCount == 4 && [pathsInPane(cc, 0) isEqualToArray:@[paths[2]]], "left body drop creates the third editor column");
    CHECK([[NSSet setWithArray:[cc valueForKey:@"_docs"]] isEqualToSet:[NSSet setWithArray:docs]], "editor moves preserve document identities without duplicates");

    NSArray *hosts = split.items.copy, *beforeDocs = [[cc valueForKey:@"_docs"] copy];
    [cc focusPane:1];
    CHECK(cc.editor == original && [text(original) isEqualToString:edited], "splitting preserves the edited view and buffer");
    NSView *attached = original.superview;
    dropContent(editorBars(cc)[1], 0, NO, split.items[2], FTTabDropAfter, NO);
    CHECK(cc.paneCount == 3 && cc.tabCount == 4 && [split.items isEqualToArray:hosts] &&
          [[cc valueForKey:@"_docs"] isEqualToArray:beforeDocs] && original.superview == attached,
          "the fourth editor split refuses before detaching a tab or view");
    dividerDrag(window, split, "editor");

    // A sole source column can relocate at the cap without consuming a fourth slot.
    dropContent(editorBars(cc)[0], 0, NO, split.items[2], FTTabDropAfter, YES);
    CHECK(cc.paneCount == 3 && [pathsInPane(cc, 2) isEqualToArray:@[paths[2]]], "sole editor column relocates at the cap");
    dropContent(editorBars(cc)[2], 0, NO, split.items[0], FTTabDropBefore, YES);
    dropContent(editorBars(cc)[1], 0, NO, split.items[0], FTTabDropInto, YES);
    CHECK(cc.paneCount == 3 && [pathsInPane(cc, 1) isEqualToArray:@[paths[3]]], "central drop keeps the middle column's remaining tab");
    dropContent(editorBars(cc)[1], 0, NO, split.items[0], FTTabDropInto, YES);
    CHECK(cc.paneCount == 2 && cc.tabCount == 4 && [pathsInPane(cc, 1) isEqualToArray:@[paths[1]]], "empty middle editor column disappears without losing the right tab");
    for (NSUInteger i = 0; i < 3 && cc.paneCount == 2; i++)
        dropInBar(editorBars(cc)[0], 0, NO, editorBars(cc)[1], (NSInteger)editorBars(cc)[1].items.count);
    CHECK(cc.paneCount == 1 && cc.tabCount == 4 && ([pathsInPane(cc, 0) isEqualToArray:@[paths[1], paths[2], paths[0], paths[3]]]),
          "Into tab-strip merges delete the left column and preserve every tab in order");
    [cc openPath:paths[0] preview:NO focus:YES];
    CHECK(cc.editor == original && [text(original) isEqualToString:edited], "central merges preserve the original editor and unsaved contents");
    [original undo:nil];
    CHECK([text(original) isEqualToString:@"alpha\nbeta\n"], "the moved editor keeps its undo history");

    // Closing the last tabs of middle and left columns also preserves neighbouring tabs.
    dropContent(editorBars(cc)[0], 1, NO, split.items[0], FTTabDropBefore, YES);
    dropContent(editorBars(cc)[1], 0, NO, split.items[1], FTTabDropAfter, YES);
    [cc focusPane:1];
    [cc closeActive];
    CHECK(cc.paneCount == 3 && cc.tabCount == 3, "closing one middle editor tab retains its sibling");
    [cc closeActive];
    CHECK(cc.paneCount == 2 && cc.tabCount == 2 && [pathsInPane(cc, 0) isEqualToArray:@[paths[2]]] &&
          [pathsInPane(cc, 1) isEqualToArray:@[paths[1]]], "deleting the middle editor column preserves left and right tabs");
    [cc focusPane:0]; [cc closeActive];
    CHECK(cc.paneCount == 1 && cc.tabCount == 1 && [cc.currentPath isEqualToString:paths[1]], "deleting the left editor column preserves the right tab");

    [cc closeAllWithoutAsking];
    [cc openPath:paths[0] preview:NO focus:YES];
    TextEditorView *cleanTarget = cc.editor;
    [cc splitEditor];
    dropContent(editorBars(cc)[1], 0, NO, split.items[0], FTTabDropInto, YES);
    CHECK(cc.paneCount == 1 && cc.tabCount == 1 && cc.editor == cleanTarget, "clean splitEditor duplicates merge into the existing target view");
    [cc closeAllWithoutAsking];
}

static void checkPanelIdentities(TerminalPanel *panel, NSArray<TSession *> *sessions, NSArray<NSView *> *views,
                                 NSArray *screens, NSArray<NSNumber *> *pids, NSArray<NSNumber *> *ptys) {
    CHECK(panel.tabCount == sessions.count && panel.sessions.count == sessions.count &&
          [[NSSet setWithArray:panel.sessions] isEqualToSet:[NSSet setWithArray:sessions]],
          "panel keeps every session exactly once (%lu tabs, %lu expected)", (unsigned long)panel.tabCount, (unsigned long)sessions.count);
    CHECK(panel.columnViews.count == panel.columnCount && panel.tabBars.count == panel.columnCount,
          "panel exposes one host and tab bar per column");
    NSUInteger tabs = 0;
    for (NSUInteger col = 0; col < panel.columnCount; col++) {
        CHECK([panel.columnViews[col] isKindOfClass:FTTabDropView.class], "terminal column %lu is a drop host", (unsigned long)col);
        tabs += panel.tabBars[col].items.count;
    }
    CHECK(tabs == sessions.count, "column tab counts match the flattened sessions");
    for (NSUInteger i = 0; i < sessions.count; i++) {
        TSession *session = sessions[i];
        [panel focusSession:session];
        CHECK(panel.activeSession == session && panel.currentView == views[i] && [(TerminalView *)panel.currentView session] == session,
              "terminal %lu keeps the same session and view", (unsigned long)i);
        CHECK(session.screen == screens[i] && session.pid == pids[i].intValue && [[session valueForKey:@"_master"] isEqual:ptys[i]] && !session.exited,
              "terminal %lu keeps its screen, process and PTY descriptor", (unsigned long)i);
        CHECK([panel.currentView isDescendantOf:panel] && panel.window.firstResponder == panel.currentView,
              "terminal %lu is attached and focusable after the move", (unsigned long)i);
    }
}

static void terminalPanelDrops(ContentController *cc, NSWindow *window, NSString *directory) {
    NSMutableArray<TSession *> *sessions = [NSMutableArray array];
    NSMutableArray<NSView *> *views = [NSMutableArray array];
    NSMutableArray *screens = [NSMutableArray array], *pids = [NSMutableArray array], *ptys = [NSMutableArray array];
    TerminalPanel *panel = [cc valueForKey:@"_terminalPanel"];
    for (NSUInteger i = 0; i < 6; i++) {
        TSession *session = trackShell([cc openTerminalAt:directory asTab:NO]);
        if (!session) return;
        [sessions addObject:session]; [views addObject:panel.currentView];
        [screens addObject:session.screen]; [pids addObject:@(session.pid)]; [ptys addObject:[session valueForKey:@"_master"]];
        CHECK(panel.columnCount == 1 && panel.tabBars[0].items.count == i + 1,
              "new terminal %lu joins the focused column as a tab", (unsigned long)i + 1);
    }
    CHECK(cc.terminalCount == 6 && panel.tabCount == 6 && panel.columnCount == 1 && cc.terminalPanelVisible,
          "terminal session count is independent of the three-column cap");
    CHECK([panel.sessions isEqualToArray:sessions], "new terminal tabs preserve their creation order");
    TSession *t0 = sessions[0], *t1 = sessions[1], *t2 = sessions[2];
    tabDragLifecycle(panel.tabBars[0]);
    invalidDropTokens(panel.tabBars[0], (FTTabDropView *)panel.columnViews[0], YES);
    [panel refreshTitles];
    CHECK(panel.tabBars[0].items.count == 6 && panel.tabBars[0].items[0].title.length, "refreshTitles covers all tabs");

    TabBarView *bar = panel.tabBars[0];
    NSString *token = dragToken(bar, 0, YES);
    CHECK([TSession sessionForDragToken:token] == t0 && bar.canDropTab(token, YES) && bar.onDropTab(token, YES, 6),
          "terminal source and same-bar drop callbacks reorder the original session");
    CHECK(panel.sessions.lastObject == t0 && panel.sessions.count == 6, "forward terminal reorder uses a pre-removal insertion index");
    dropInBar(panel.tabBars[0], 5, YES, panel.tabBars[0], 0);
    CHECK([panel.sessions isEqualToArray:sessions], "tab strip moves the last terminal tab back to the start");

    if (!dropContent(panel.tabBars[0], 1, YES, panel.columnViews[0], FTTabDropAfter, YES)) return;
    CHECK(panel.columnCount == 2 && panel.tabBars[0].items.count == 5 && panel.tabBars[1].items.count == 1 && panel.activeSession == t1,
          "right content drop creates a column from one terminal tab");
    if (!dropContent(panel.tabBars[0], 1, YES, panel.columnViews[0], FTTabDropBefore, YES)) return;
    CHECK(panel.columnCount == 3 && panel.tabBars[0].items.count == 1 && panel.tabBars[1].items.count == 4 && panel.activeSession == t2,
          "left content drop creates the third terminal column");
    checkPanelIdentities(panel, sessions, views, screens, pids, ptys);
    FTSplitView *split = [panel valueForKey:@"_split"];
    dividerDrag(window, split, "terminal");

    [panel focusSession:t0];
    NSArray *beforeSessions = panel.sessions, *beforeHosts = panel.columnViews, *beforeBars = panel.tabBars;
    NSView *parent = views[0].superview;
    dropContent(panel.tabBars[1], 0, YES, panel.columnViews[2], FTTabDropAfter, NO);
    CHECK(panel.columnCount == 3 && cc.terminalCount == 6 && [panel.sessions isEqualToArray:beforeSessions] &&
          [panel.columnViews isEqualToArray:beforeHosts] && [panel.tabBars isEqualToArray:beforeBars] && views[0].superview == parent,
          "a fourth terminal split is refused without detaching sessions, tabs, hosts or views");

    // A full split still accepts a new tab in the focused column.
    TSession *extra = trackShell([cc openTerminalAt:directory asTab:NO]);
    if (!extra) return;
    [sessions addObject:extra]; [views addObject:panel.currentView]; [screens addObject:extra.screen];
    [pids addObject:@(extra.pid)]; [ptys addObject:[extra valueForKey:@"_master"]];
    CHECK(panel.columnCount == 3 && panel.tabCount == 7 && cc.terminalCount == 7 && panel.tabBars[1].items.count == 5,
          "new terminal is an additional tab even with all three column slots occupied");
    NSView *soleHost = panel.columnViews[0];
    dropContent(panel.tabBars[0], 0, YES, panel.columnViews[2], FTTabDropAfter, YES);
    CHECK(panel.columnCount == 3 && panel.columnViews[2] == soleHost && panel.sessions.lastObject == t2,
          "sole terminal column relocates at the cap with its original host");
    dropContent(panel.tabBars[2], 0, YES, panel.columnViews[0], FTTabDropBefore, YES);

    dropContent(panel.tabBars[1], 0, YES, panel.columnViews[0], FTTabDropInto, YES);
    CHECK(panel.columnCount == 3 && panel.tabBars[1].items.count == 4 && panel.activeSession == t0,
          "central terminal body drop merges a tab while preserving source siblings");
    for (NSUInteger i = 0; i < 4 && panel.columnCount == 3; i++)
        dropContent(panel.tabBars[1], 0, YES, panel.columnViews[0], FTTabDropInto, YES);
    CHECK(panel.columnCount == 2 && panel.tabCount == 7 && panel.tabBars[1].items.count == 1 && panel.sessions.lastObject == t1,
          "merging the middle terminal column preserves the right column's tab");
    for (NSUInteger i = 0; i < 6 && panel.columnCount == 2; i++)
        dropInBar(panel.tabBars[0], 0, YES, panel.tabBars[1], (NSInteger)panel.tabBars[1].items.count);
    CHECK(panel.columnCount == 1 && panel.tabCount == 7 &&
          ([panel.sessions isEqualToArray:@[t1, t2, t0, sessions[3], sessions[4], sessions[5], extra]]),
          "Into existing tabs removes the left terminal column without losing or duplicating sessions");
    checkPanelIdentities(panel, sessions, views, screens, pids, ptys);

    // Focus follows both explicit tab selection and a responder in another column.
    dropContent(panel.tabBars[0], 1, YES, panel.columnViews[0], FTTabDropBefore, YES);
    dropContent(panel.tabBars[1], 0, YES, panel.columnViews[1], FTTabDropAfter, YES);
    CHECK(panel.columnCount == 3 && panel.tabBars[1].items.count == 5, "terminal close fixtures have tabs in the middle column");
    [panel focusSession:t2];
    [window makeFirstResponder:views[1]];
    [panel syncFocus];
    CHECK(panel.activeSession == t1 && panel.currentView == views[1], "syncFocus follows the existing terminal view into its column");
    CHECK(!panel.isMaximized, "terminal splitting and focus keep expansion disabled by default");
    NSArray<NSNumber *> *widths = split.weights;
    FTSplitView *editorSplit = [cc valueForKey:@"_split"];
    BOOL editorMaximized = editorSplit.isMaximized;
    doubleClickTab(window, panel.tabBars[2], 0);
    CHECK(panel.isMaximized && fabs(split.items[2].frame.size.width - (split.bounds.size.width - 360)) <= 1,
          "a terminal tab double-click expands the responder's group and retains usable neighbours");
    CHECK(editorSplit.isMaximized == editorMaximized, "terminal expansion leaves the editor area unchanged");
    [panel focusSession:t2];
    CHECK(fabs(split.items[0].frame.size.width - (split.bounds.size.width - 360)) <= 1, "terminal expansion follows focusSession while enabled");
    doubleClickTab(window, panel.tabBars[0], 0);
    CHECK(!panel.isMaximized && [split.weights isEqualToArray:widths], "another terminal tab double-click restores stored widths");
    [panel focusSession:t1];
    CHECK(!panel.isMaximized && [split.weights isEqualToArray:widths], "terminal focus never re-enables disabled expansion");

    // Prove the preserved PTY still executes commands after all the moves.
    NSString *marker = [directory stringByAppendingPathComponent:@"terminal-moved"];
    [t0 writeString:[NSString stringWithFormat:@"printf '%%s' 'pty-' 'survived' > '%@'\n", marker]];
    CFAbsoluteTime until = CFAbsoluteTimeGetCurrent() + 5;
    NSString *movedOutput;
    do {
        movedOutput = [[NSString alloc] initWithContentsOfFile:marker encoding:NSUTF8StringEncoding error:nil];
        if ([movedOutput isEqualToString:@"pty-survived"]) break;
        drain(.05);
    } while (CFAbsoluteTimeGetCurrent() < until);
    CHECK([movedOutput isEqualToString:@"pty-survived"],
          "the original terminal PTY executes a command after split, reorder and merge (result=%s, running=%d, screen=%s)",
          movedOutput.UTF8String, t0.running, [t0.screen textOfRow:t0.screen.cursorRow].UTF8String);

    // Flattened close indices remove only the selected tab, then empty columns.
    [panel closeTabAtIndex:1];
    CHECK(panel.columnCount == 3 && panel.tabCount == 6 && ![panel containsSession:t0] && panel.tabBars[1].items.count == 4,
          "closing one middle terminal tab preserves the remaining tabs");
    for (NSUInteger i = 0; i < 4 && panel.columnCount == 3; i++) [panel closeTabAtIndex:1];
    CHECK(panel.columnCount == 2 && panel.tabCount == 2 && ([panel.sessions isEqualToArray:@[t2, t1]]),
          "deleting the middle terminal column preserves both neighbours");
    [panel closeTabAtIndex:0];
    CHECK(panel.columnCount == 1 && panel.tabCount == 1 && panel.activeSession == t1 && panel.currentView == views[1],
          "deleting the left terminal column preserves the right tab and view");
    CHECK(![panel moveSession:t1 toColumn:9 zone:FTTabDropInto index:0] && panel.tabCount == 1,
          "an invalid destination column leaves the remaining terminal intact");
    [cc shutdownTerminals];
    [panel closeTabAtIndex:0];
    CHECK(panel.columnCount == 0 && panel.tabCount == 0 && cc.terminalCount == 0 && !cc.terminalPanelVisible,
          "closing the final terminal hides the empty panel");
}

// Columns of editors and columns of terminals, free divider drags, and maximize that follows focus.
static void splits(void) {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *a = [dir stringByAppendingPathComponent:@"a.txt"], *b = [dir stringByAppendingPathComponent:@"b.txt"];
    NSString *c = [dir stringByAppendingPathComponent:@"c.txt"], *d = [dir stringByAppendingPathComponent:@"d.txt"];
    [@"alpha\nbeta\n" writeToFile:a atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"one\ntwo\nthree\n" writeToFile:b atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"third file\n" writeToFile:c atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"fourth file\n" writeToFile:d atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSWindow *sw = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 480) styleMask:NSWindowStyleMaskTitled
                                               backing:NSBackingStoreBuffered defer:YES];
    ContentController *cc = testController();
    sw.contentView = cc.view;
    [sw makeKeyAndOrderFront:nil];
    drain(0.2);
    CHECK(cc.paneCount == 1, "starts with one column");
    focusedSplitGroups(sw);

    [cc openPath:a preview:YES focus:YES];
    CHECK(cc.tabCount == 1 && cc.editor != nil, "a file in column 1");
    doubleClickTab(sw, editorBars(cc)[0], 0);
    CHECK(![[[[cc valueForKey:@"_docs"] firstObject] valueForKey:@"preview"] boolValue] && !cc.focusedAreaMaximized,
          "double-click keeps a single-column preview open without enabling expansion");
    [cc splitEditor];
    CHECK(cc.paneCount == 2 && cc.tabCount == 2, "⌘\\ duplicates the active file into a second column (p %lu, t %lu)",
          (unsigned long)cc.paneCount, (unsigned long)cc.tabCount);
    FTSplitView *split = [cc valueForKey:@"_split"];
    CHECK(split.items.count == 2, "the split container has both columns");
    CGFloat total = split.items[0].frame.size.width + split.items[1].frame.size.width;
    CHECK(fabs(total - sw.frame.size.width) < 4, "the columns fill the width (%.0f vs %.0f)", total, sw.frame.size.width);
    CHECK(split.items[0].frame.size.width > 100, "both columns are usable: %.0f", split.items[0].frame.size.width);

    // the new file opens in the focused (second) column; each column remembers its own tab
    [cc openPath:b preview:NO focus:YES];
    CHECK(cc.tabCount == 3 && [cc.currentPath isEqualToString:b], "b.txt joined column 2");
    [cc focusPane:0];
    CHECK([cc.currentPath isEqualToString:a], "⌘1 shows column 1's tab");
    [cc focusPane:1];
    CHECK([cc.currentPath isEqualToString:b], "⌘2 shows column 2's tab");
    // the same file is already a tab of this column: opening it again just activates that tab
    [cc openPath:a preview:NO focus:YES];
    CHECK(cc.tabCount == 3 && [cc.currentPath isEqualToString:a], "a path stays unique within its column");

    // closing tabs merges an emptied column away
    [cc closeActive];                                      // the a-dup goes, b stays in column 2
    CHECK(cc.paneCount == 2 && cc.tabCount == 2 && [cc.currentPath isEqualToString:b], "column 2 keeps its other tab (p %lu, t %lu)",
          (unsigned long)cc.paneCount, (unsigned long)cc.tabCount);
    [cc closeActive];                                      // b was column 2's last tab: the column goes
    CHECK(cc.paneCount == 1 && cc.tabCount == 1 && [cc.currentPath isEqualToString:a], "back to one column on column 1's tab (p %lu, t %lu)",
          (unsigned long)cc.paneCount, (unsigned long)cc.tabCount);

    // three columns, not four
    [cc splitEditor]; [cc splitEditor];
    CHECK(cc.paneCount == 3 && cc.tabCount == 3, "three columns");
    [cc splitEditor];
    CHECK(cc.paneCount == 3, "the fourth split is refused");

    // maximize: the focused column wide, the others as narrow strips at the edges — and it follows the focus
    [cc focusPane:1];
    [cc openPath:b preview:NO focus:YES];
    CHECK(cc.tabCount == 4, "b.txt joined the middle column");
    CHECK(!split.isMaximized, "editor splitting and focus keep expansion disabled by default");
    NSArray<NSNumber *> *widths = split.weights;
    doubleClickTab(sw, editorBars(cc)[1], 1);
    CHECK(split.isMaximized && [cc.currentPath isEqualToString:b], "double-clicking an editor tab enables expansion in its group");
    CHECK(fabs(split.items[0].frame.size.width - 180) <= 1 && fabs(split.items[2].frame.size.width - 180) <= 1,
          "unfocused editor groups retain a usable minimum width");
    CHECK(fabs(split.items[1].frame.size.width - (split.bounds.size.width - 360)) <= 1,
          "the focused editor group receives the remaining width");
    [cc focusPane:2];
    CHECK(fabs(split.items[2].frame.size.width - (split.bounds.size.width - 360)) <= 1 && fabs(split.items[1].frame.size.width - 180) <= 1,
          "automatic expansion follows editor focus");
    doubleClickTab(sw, editorBars(cc)[2], 0);
    CHECK(!split.isMaximized && [split.weights isEqualToArray:widths], "a second tab double-click restores stored editor widths");
    [cc focusPane:0];
    CHECK(!split.isMaximized && [split.weights isEqualToArray:widths], "focus after disabling expansion retains ordinary widths");
    [cc toggleMaximize];
    CHECK(split.isMaximized, "the explicit shortcut can still enable group expansion");
    [cc toggleMaximize];
    CHECK(!split.isMaximized, "the explicit shortcut can also disable group expansion");

    // A preview tab needs two double-clicks: the first keeps it open, the second expands.
    previewTabDoubleClick(cc, sw, split, c);

    // Dividers must be reached through the window root, even with translated split origins.
    dividerDrag(sw, split, "editor baseline");
    editorDrops(cc, sw, @[a, b, c, d]);
    terminalPanelDrops(cc, sw, dir);

    // the session remembers which column each tab lives in
    [cc closeAllWithoutAsking];
    [cc openPath:a preview:NO focus:YES];
    [cc splitEditor];
    [cc openPath:b preview:NO focus:YES];
    NSDictionary *st = [cc sessionState];
    CHECK([st[@"tabs"] count] == 3 && [st[@"tabs"][0][@"pane"] integerValue] == 0 && [st[@"tabs"][2][@"pane"] integerValue] == 1,
          "the session stores the columns");
    [cc restoreSession:st];
    CHECK(cc.paneCount == 2 && cc.tabCount == 3, "restoring brings both columns back (p %lu, t %lu)",
          (unsigned long)cc.paneCount, (unsigned long)cc.tabCount);
    [cc closeAllWithoutAsking];
    CHECK(cc.paneCount == 1 && cc.tabCount == 0, "closing everything collapses to one column");
    commandWheelZoom(cc, sw, a);
    drain(0.3);
    [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
}
