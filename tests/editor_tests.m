// Drives the real TextEditorView / ContentController in an offscreen window.
#import <Cocoa/Cocoa.h>
#import "TextEditorView+Private.h"
#import "ContentController.h"
#import "AppDelegate.h"
#import "FileTree.h"
#import "Viewers.h"
#import "MarkupView.h"
#import "MarkdownRender.h"
#import "TabBarView.h"
#import "PDFViewer.h"
#import "DefaultAppsPanel.h"
#import "WorkspaceSearch.h"
#import "TablePreview.h"
#import "TableModel.h"
#import "TreePreview.h"
#import "BinaryPreviews.h"
#import "JSONTree.h"
#import "Settings.h"
#import "SettingsWindow.h"
#import "Localization.h"
#import "OfficeViews.h"
#import "SheetGrid.h"
#import "XLWorkbook.h"
#include "xlsx_fixture.h"
#include <sqlite3.h>
#import <PDFKit/PDFKit.h>
#include <sys/stat.h>
#include <sys/xattr.h>

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while (0)

static NSString *text(TextEditorView *ed) {
    return [[NSString alloc] initWithData:[ed->_buf dataInRange:NSMakeRange(0, ed->_buf.length)] encoding:NSUTF8StringEncoding];
}
static NSString *fileText(NSString *p, NSStringEncoding enc) {
    return [NSString stringWithContentsOfFile:p encoding:enc error:nil];
}

static NSString *mkfile(NSString *dir, NSString *name, NSString *content);
static ContentController *cc;
static NSWindow *win;

static TextEditorView *openEditor(NSString *path) {
    [cc openPath:path preview:NO focus:YES];
    return cc.editor;
}

static void editing(NSString *dir) {
    NSString *p = [dir stringByAppendingPathComponent:@"a.c"];
    [@"int main() {\n    return 0;\n}\n" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
    TextEditorView *ed = openEditor(p);
    CHECK(ed != nil, "editor opened");
    CHECK(!ed.isDirty, "clean on open");

    [ed insertText:@"X" replacementRange:NSMakeRange(NSNotFound, 0)];
    [ed insertText:@"Y" replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK([text(ed) hasPrefix:@"XYint"], "typing: %s", text(ed).UTF8String);
    CHECK(ed.isDirty, "dirty after typing");
    [ed undo:nil];
    CHECK([text(ed) hasPrefix:@"int main"] && !ed.isDirty, "typing coalesced into one undo");
    [ed redo:nil];
    CHECK([text(ed) hasPrefix:@"XYint"], "redo");
    [ed undo:nil];

    // caret to end of line 2 ("    return 0;"), Enter keeps indent
    [ed moveCaretTo:[ed->_buf lineEnd:1] extend:NO];
    [ed doCommandBySelector:@selector(insertNewline:)];
    [ed insertText:@"x" replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK([text(ed) containsString:@"return 0;\n    x\n}"], "auto-indent: %s", text(ed).UTF8String);

    // IME: composition is not in the buffer until committed
    [ed setMarkedText:@"zhong" selectedRange:NSMakeRange(5, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK(ed.hasMarkedText && ![text(ed) containsString:@"zhong"], "marked text kept out of buffer");
    [ed displayIfNeeded];
    [ed insertText:@"中" replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK(!ed.hasMarkedText && [text(ed) containsString:@"x中\n"], "IME commit: %s", text(ed).UTF8String);

    // backspace removes whole grapheme clusters
    [ed insertText:@"e\u0301👍🏽" replacementRange:NSMakeRange(NSNotFound, 0)];
    [ed doCommandBySelector:@selector(deleteBackward:)];
    CHECK([text(ed) containsString:@"中e\u0301\n"], "emoji+modifier deleted as one");
    [ed doCommandBySelector:@selector(deleteBackward:)];
    CHECK([text(ed) containsString:@"x中\n"], "combining accent deleted as one");
    [ed doCommandBySelector:@selector(moveLeft:)];
    [ed doCommandBySelector:@selector(moveRight:)];
    CHECK(ed->_caret == [ed->_buf lineEnd:2], "move over CJK char");

    // find (ASCII case-insensitive) + selection replace
    CHECK([ed findString:@"RETURN" backward:NO], "find");
    [ed insertText:@"yield" replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK([text(ed) containsString:@"yield 0;"], "replace selection");

    // vertical movement keeps column
    [ed gotoLine:1];
    [ed doCommandBySelector:@selector(moveToEndOfLine:)];
    [ed doCommandBySelector:@selector(moveDown:)];
    CHECK([ed->_buf lineForOffset:ed->_caret] == 1, "moveDown");

    NSString *err = nil;
    CHECK([ed save:&err] && !ed.isDirty, "save: %s", err.UTF8String);
    CHECK([fileText(p, NSUTF8StringEncoding) isEqualToString:text(ed)], "saved bytes match buffer");
    [ed undo:nil];
    CHECK(ed.isDirty, "dirty again after undo past save");

    // draw with selection + marked text into a bitmap (exercises drawRect)
    [ed selectAll:nil];
    NSBitmapImageRep *rep = [ed bitmapImageRepForCachingDisplayInRect:ed.bounds];
    [ed cacheDisplayInRect:ed.bounds toBitmapImageRep:rep];
    CHECK(rep.pixelsWide > 0, "draw");
}

static void crlfAndEncodings(NSString *dir) {
    NSString *p = [dir stringByAppendingPathComponent:@"win.txt"];
    [@"ab\r\ncd\r\n" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
    TextEditorView *ed = openEditor(p);
    [ed moveCaretTo:[ed->_buf lineStart:1] extend:NO];
    [ed doCommandBySelector:@selector(deleteBackward:)];
    CHECK([text(ed) isEqualToString:@"abcd\r\n"], "backspace removes CRLF as one: %s", text(ed).UTF8String);
    [ed doCommandBySelector:@selector(insertNewline:)];
    CHECK([text(ed) isEqualToString:@"ab\r\ncd\r\n"], "Enter inserts CRLF");
    [ed save:nil];

    NSStringEncoding gb = CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000);
    NSString *g = [dir stringByAppendingPathComponent:@"gbk.txt"];
    [@"中文内容\n第二行\n" writeToFile:g atomically:YES encoding:gb error:nil];
    ed = openEditor(g);
    CHECK(ed && ed.encoding == gb, "GB18030 detected");
    [ed moveCaretTo:ed->_buf.length extend:NO];
    [ed insertText:@"追加" replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK([ed save:nil], "save GB18030");
    CHECK([fileText(g, gb) isEqualToString:@"中文内容\n第二行\n追加"], "GB18030 round-trip");

    // Other legacy encodings are recognised, not decoded as (garbled) GB18030.
    struct { CFStringEncoding cf; NSString *text; } legacy[] = {
        {kCFStringEncodingShiftJIS, @"日本語のテキストです。東京都、こんにちは。カタカナ\n"},
        {kCFStringEncodingEUC_KR, @"한국어 텍스트입니다. 안녕하세요 서울\n"},
        {kCFStringEncodingBig5, @"繁體中文的文字。台北市，你好，這是一個測試。\n"},
        {kCFStringEncodingWindowsLatin1, @"Café “quoted” – naïve résumé €5\n"},
    };
    for (size_t k = 0; k < sizeof legacy / sizeof *legacy; k++) {
        NSStringEncoding e = CFStringConvertEncodingToNSStringEncoding(legacy[k].cf);
        NSString *lp = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"legacy%zu.txt", k]];
        [[legacy[k].text dataUsingEncoding:e] writeToFile:lp atomically:YES];
        ed = openEditor(lp);
        CHECK([text(ed) isEqualToString:legacy[k].text], "%s decoded correctly: %s", FKEncodingName(e).UTF8String, text(ed).UTF8String);
        [ed insertText:@"x" replacementRange:NSMakeRange(NSNotFound, 0)];
        CHECK([ed save:nil] && [fileText(lp, e) isEqualToString:[@"x" stringByAppendingString:legacy[k].text]], "%s saved back in the same encoding", FKEncodingName(e).UTF8String);
        [cc closeActive];
    }

    // UTF-16 keeps its byte order and BOM.
    for (int be = 0; be < 2; be++) {
        NSString *up = [dir stringByAppendingPathComponent:be ? @"be.txt" : @"le.txt"];
        NSMutableData *raw = [NSMutableData dataWithBytes:be ? "\xFE\xFF" : "\xFF\xFE" length:2];
        [raw appendData:[@"hi 中\n" dataUsingEncoding:be ? NSUTF16BigEndianStringEncoding : NSUTF16LittleEndianStringEncoding]];
        [raw writeToFile:up atomically:YES];
        ed = openEditor(up);
        [ed insertText:@"!" replacementRange:NSMakeRange(NSNotFound, 0)];
        CHECK([ed save:nil], "save UTF-16");
        NSData *back = [NSData dataWithContentsOfFile:up];
        NSMutableData *want = [NSMutableData dataWithBytes:be ? "\xFE\xFF" : "\xFF\xFE" length:2];
        [want appendData:[@"!hi 中\n" dataUsingEncoding:be ? NSUTF16BigEndianStringEncoding : NSUTF16LittleEndianStringEncoding]];
        CHECK([back isEqualToData:want], "UTF-16 %s saved in the same byte order: %s", be ? "BE" : "LE", back.description.UTF8String);
        CHECK([ed.statusText containsString:be ? @"UTF-16 BE" : @"UTF-16 LE"], "status names it: %s", ed.statusText.UTF8String);
        [cc closeActive];
    }

    // Saving keeps the file's extended attributes (Finder tags) and its other hard links.
    NSString *tagged = mkfile(dir, @"tagged.txt", @"t\n");
    setxattr(tagged.fileSystemRepresentation, "com.example.feather-test", "tag", 3, 0, 0);
    ed = openEditor(tagged);
    [ed insertText:@"x" replacementRange:NSMakeRange(NSNotFound, 0)];
    char xv[8] = {0};
    CHECK([ed save:nil] && getxattr(tagged.fileSystemRepresentation, "com.example.feather-test", xv, sizeof xv, 0, 0) == 3 && !strcmp(xv, "tag"),
          "an extended attribute survives saving");
    [cc closeActive];
    NSString *linkA = mkfile(dir, @"linkA.txt", @"shared\n"), *linkB = [dir stringByAppendingPathComponent:@"linkB.txt"];
    link(linkA.fileSystemRepresentation, linkB.fileSystemRepresentation);
    ed = openEditor(linkA);
    [ed insertText:@"edited " replacementRange:NSMakeRange(NSNotFound, 0)];
    struct stat sa, sb;
    CHECK([ed save:nil] && [fileText(linkB, NSUTF8StringEncoding) isEqualToString:@"edited shared\n"] &&
          stat(linkA.fileSystemRepresentation, &sa) == 0 && stat(linkB.fileSystemRepresentation, &sb) == 0 && sa.st_ino == sb.st_ino,
          "a hard-linked file is saved in place, so the other link sees the change");
    [ed insertText:@"again " replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK([ed save:nil] && [fileText(linkB, NSUTF8StringEncoding) isEqualToString:@"edited again shared\n"], "and again");
    [cc closeActive];
}

static void replaceAndJump(NSString *dir) {
    NSString *p = [dir stringByAppendingPathComponent:@"r.txt"];
    [@"foo Foo\nbar foo\n中文foo\n" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
    TextEditorView *ed = openEditor(p);
    NSUInteger n = [ed replaceAll:@"foo" with:@"foofoo"];
    CHECK(n == 4 && [text(ed) isEqualToString:@"foofoo foofoo\nbar foofoo\n中文foofoo\n"], "replaceAll %lu: %s", n, text(ed).UTF8String);
    [ed undo:nil];
    CHECK([text(ed) isEqualToString:@"foo Foo\nbar foo\n中文foo\n"] && !ed.isDirty, "replaceAll is one undo step");
    CHECK([ed replaceAll:@"o" with:@""] == 8 && [text(ed) isEqualToString:@"f F\nbar f\n中文f\n"], "replace with empty");
    [ed undo:nil];

    [ed moveCaretTo:0 extend:NO];
    [ed findString:@"foo" backward:NO];
    CHECK([ed replaceSelectionIfMatches:@"foo" with:@"X"], "replace current match");
    CHECK([text(ed) hasPrefix:@"X Foo"] && ed.selection.location == 2, "then selects next match");
    CHECK(![ed replaceSelectionIfMatches:@"zzz" with:@"Y"], "non-matching selection untouched");
    [ed undo:nil];

    // rg columns are 1-based byte offsets; "中文" is 6 bytes
    [ed selectLine:3 column:7 length:3];
    CHECK([[ed selectedText] isEqualToString:@"foo"], "selectLine on CJK line: %s", ed.selectedText.UTF8String);
    [ed selectLine:99 column:1 length:3];
    CHECK([ed->_buf lineForOffset:ed->_caret] == ed->_buf.lineCount - 1, "selectLine clamps");

    // openHit from another file + following a rename
    NSString *other = [dir stringByAppendingPathComponent:@"o.txt"];
    [@"x\ny target\n" writeToFile:other atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [cc openHit:other line:2 column:3 length:6];
    CHECK([cc.editor.path isEqualToString:other] && [cc.editor.selectedText isEqualToString:@"target"], "openHit");
    NSString *moved = [dir stringByAppendingPathComponent:@"moved.c"];
    rename(other.fileSystemRepresentation, moved.fileSystemRepresentation);
    [cc pathMoved:other to:moved];
    CHECK([cc.currentPath isEqualToString:moved] && [cc.editor.path isEqualToString:moved], "follows rename");
    [cc.editor insertText:@"!" replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK([cc save] && [fileText(moved, NSUTF8StringEncoding) containsString:@"y !\n"], "saves to new path");
    [cc pathMoved:@"/nonexistent" to:@"/elsewhere"];
    CHECK([cc.currentPath isEqualToString:moved], "unrelated rename ignored");
}

static void tree(NSString *dir) {
    NSString *sub = [dir stringByAppendingPathComponent:@"sub/deep"];
    [NSFileManager.defaultManager createDirectoryAtPath:sub withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *f = [sub stringByAppendingPathComponent:@"leaf.txt"];
    [@"x" writeToFile:f atomically:YES encoding:NSUTF8StringEncoding error:nil];
    FileOutlineView *ov = [[FileOutlineView alloc] initWithFrame:NSMakeRect(0, 0, 200, 400)];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"n"];
    [ov addTableColumn:col];
    ov.outlineTableColumn = col;
    FileTree *t = [[FileTree alloc] initWithOutlineView:ov];
    __block NSUInteger fired = 0;
    t.onOpen = ^(NSString *p, BOOL pinned) { fired++; };
    t.rootPath = dir;
    [t revealPath:f];
    CHECK([t.selectedPath isEqualToString:f], "reveal selects nested file: %s", t.selectedPath.UTF8String);
    [t reload];
    CHECK([t.selectedPath isEqualToString:f], "reload keeps selection");
    NSString *g = [sub stringByAppendingPathComponent:@"new.txt"];
    [@"" writeToFile:g atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [t reloadAndReveal:g];
    CHECK([t.selectedPath isEqualToString:g], "reloadAndReveal picks up new file");
    [t revealPath:[dir stringByAppendingPathComponent:@"nope/x"]];
    CHECK(t.selectedPath == nil, "missing path clears selection");
    [t revealPath:[dir stringByAppendingString:@"-sibling/x"]];
    CHECK(fired == 0, "programmatic selection never fires onOpen (%lu)", (unsigned long)fired);
}

static NSString *mkfile(NSString *dir, NSString *name, NSString *content) {
    NSString *p = [dir stringByAppendingPathComponent:name];
    [content writeToFile:p atomically:NO encoding:NSUTF8StringEncoding error:nil];
    return p;
}

// clickedRow is only set during a real mouse event; let the test say which row was right-clicked.
@interface FakeClickOutline : FileOutlineView
@property (nonatomic) NSInteger fakeClickedRow;
@end
@implementation FakeClickOutline
- (NSInteger)clickedRow { return _fakeClickedRow; }
@end

static void treeMultiSelect(NSString *dir) {
    NSString *root = [dir stringByAppendingPathComponent:@"multi"];
    NSString *sub = [root stringByAppendingPathComponent:@"folder"];
    [NSFileManager.defaultManager createDirectoryAtPath:sub withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *a = mkfile(root, @"a.txt", @"a"), *b = mkfile(root, @"b.txt", @"b"), *c = mkfile(root, @"c.txt", @"c");
    NSString *x = mkfile(sub, @"x.txt", @"x");
    FakeClickOutline *ov = [[FakeClickOutline alloc] initWithFrame:NSMakeRect(0, 0, 200, 400)];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"n"];
    [ov addTableColumn:col];
    ov.outlineTableColumn = col;
    FileTree *t = [[FileTree alloc] initWithOutlineView:ov];
    __block NSUInteger fired = 0;
    t.onOpen = ^(NSString *p, BOOL pinned) { fired++; };
    t.rootPath = root;
    CHECK(ov.allowsMultipleSelection, "tree allows ⇧ / ⌘ multi-selection");

    [t revealPaths:@[c, x, a]];
    CHECK([t.selectedPaths isEqualToArray:(@[x, a, c])], "several items selected, in row order (folders first): %s",
          [[t.selectedPaths valueForKey:@"lastPathComponent"] componentsJoinedByString:@","].UTF8String);
    [t reload];
    CHECK(t.selectedPaths.count == 3, "reload keeps the whole selection (%lu)", (unsigned long)t.selectedPaths.count);

    ov.fakeClickedRow = [ov rowForItem:[ov itemAtRow:ov.selectedRowIndexes.lastIndex]];      // right-click inside the selection
    CHECK(t.clickedPaths.count == 3, "right-click on a selected row acts on the whole selection");
    NSInteger bRow = -1;
    for (NSInteger r = 0; r < ov.numberOfRows; r++) if ([[(FileNode *)[ov itemAtRow:r] path] isEqual:b]) bRow = r;
    ov.fakeClickedRow = bRow;
    CHECK([t.clickedPaths isEqualToArray:@[b]], "right-click on an unselected row acts on just that row");
    ov.fakeClickedRow = -1;
    CHECK(t.clickedPaths.count == 0, "right-click on empty space: no rows");
    CHECK(fired == 0, "changing the selection never opened a file (%lu)", (unsigned long)fired);

    // the click action reads the modifier keys from the current event: make a real one current
    void (^clickWith)(NSEventModifierFlags) = ^(NSEventModifierFlags flags) {
        NSEvent *e = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:NSZeroPoint modifierFlags:flags
                                       timestamp:0 windowNumber:0 context:nil eventNumber:0 clickCount:1 pressure:0];
        [NSApp postEvent:e atStart:YES];
        [NSApp nextEventMatchingMask:NSEventMaskLeftMouseUp untilDate:[NSDate distantFuture] inMode:NSDefaultRunLoopMode dequeue:YES];
        ov.fakeClickedRow = bRow;
        [ov sendAction:ov.action to:ov.target];
    };
    [t revealPath:b];
    clickWith(NSEventModifierFlagShift);
    clickWith(NSEventModifierFlagCommand);
    CHECK(fired == 0, "⇧-click / ⌘-click only select, no preview opens (%lu)", (unsigned long)fired);
    clickWith(0);
    CHECK(fired == 1, "a plain click still opens the file");
}

static void multiSelectActions(NSString *dir) {
    NSString *ws = [dir stringByAppendingPathComponent:@"ws_multi"];
    NSString *sub = [ws stringByAppendingPathComponent:@"folder"];
    [NSFileManager.defaultManager createDirectoryAtPath:sub withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *a = mkfile(ws, @"a.txt", @"a"), *b = mkfile(ws, @"b.txt", @"b"), *keep = mkfile(ws, @"keep.txt", @"k");
    NSString *x = mkfile(sub, @"x.txt", @"x");
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    for (NSString *k in @[@"sessions", @"NSWindow Frame FeatherMain"]) [ud removeObjectForKey:k];
    [ud setObject:ws forKey:@"lastRoot"];
    AppDelegate *d = [AppDelegate new];
    [d applicationWillFinishLaunching:[NSNotification notificationWithName:NSApplicationWillFinishLaunchingNotification object:NSApp]];
    [d applicationDidFinishLaunching:[NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:NSApp]];
    d->_content.alertHandler = ^NSModalResponse(NSAlert *al) { return NSAlertThirdButtonReturn; };
    NSMutableArray *trashed = [NSMutableArray array];
    d->_trashHandler = ^NSString *(NSString *p) {                 // never the real Trash
        [trashed addObject:p];
        return [NSFileManager.defaultManager removeItemAtPath:p error:nil] ? nil : @"失败";
    };
    NSPasteboard *pb = [NSPasteboard pasteboardWithUniqueName];
    d->_pasteboard = pb;

    [d->_content openPath:a preview:NO focus:NO];
    [d->_content openPath:x preview:NO focus:NO];
    [d->_tree revealPaths:@[a, b, sub, x]];
    NSMenuItem *trash = [[NSMenuItem alloc] initWithTitle:@"移到废纸篓" action:@selector(trashItem:) keyEquivalent:@""];
    NSMenuItem *rename = [[NSMenuItem alloc] initWithTitle:@"重命名…" action:@selector(renameItem:) keyEquivalent:@""];
    NSMenuItem *copy = [[NSMenuItem alloc] initWithTitle:@"拷贝路径" action:@selector(copyItemPath:) keyEquivalent:@""];
    BOOL trashOK = [d validateMenuItem:trash], renameOK = [d validateMenuItem:rename];
    [d validateMenuItem:copy];
    CHECK(trashOK && [trash.title isEqualToString:@"Move 3 Items to Trash"], "menu counts 3 items (folder/x.txt goes with its folder): %s", trash.title.UTF8String);
    CHECK(!renameOK, "rename is off with several items selected");
    CHECK([copy.title isEqualToString:@"Copy 4 Paths"], "copy path title: %s", copy.title.UTF8String);

    [d copyItemPath:nil];
    CHECK([[pb stringForType:NSPasteboardTypeString] componentsSeparatedByString:@"\n"].count == 4, "copy path puts one path per line");

    [d trashItem:nil];
    NSFileManager *fm = NSFileManager.defaultManager;
    CHECK(trashed.count == 3 && ![fm fileExistsAtPath:a] && ![fm fileExistsAtPath:b] && ![fm fileExistsAtPath:sub] && [fm fileExistsAtPath:keep],
          "⌘⌫ trashes every selected item, once each (%lu calls)", (unsigned long)trashed.count);
    CHECK(d->_content.tabCount == 0, "tabs of trashed files are closed (%lu left)", (unsigned long)d->_content.tabCount);

    [d->_tree revealPaths:@[keep]];
    CHECK([d validateMenuItem:rename] && [d validateMenuItem:trash] && [trash.title isEqualToString:@"Move to Trash"], "one item: rename back on, plain title");
    [pb releaseGlobally];
    [d->_content closeAllWithoutAsking];
    for (NSString *k in @[@"lastRoot", @"sessions", @"recentRoots", @"NSWindow Frame FeatherMain"]) [ud removeObjectForKey:k];
}

static void tabs(NSString *dir) {
    NSWindow *w2 = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 600) styleMask:NSWindowStyleMaskTitled
                                                 backing:NSBackingStoreBuffered defer:YES];
    ContentController *t = [ContentController new];
    t.view.frame = w2.contentView.bounds;
    w2.contentView = t.view;
    __block NSModalResponse answer = NSAlertThirdButtonReturn;
    __block NSUInteger asked = 0;
    t.alertHandler = ^NSModalResponse(NSAlert *a) { asked++; return answer; };
    NSString *a = mkfile(dir, @"t1.txt", @"one\n"), *b = mkfile(dir, @"t2.txt", @"two\n"), *c = mkfile(dir, @"t3.txt", @"three\n");

    [t openPath:a preview:YES focus:NO];
    CHECK(t.tabCount == 1 && [t.currentPath isEqualToString:a], "single click opens a preview tab");
    [t openPath:b preview:YES focus:NO];
    CHECK(t.tabCount == 1 && [t.currentPath isEqualToString:b], "next single click replaces the preview tab");
    [t openPath:b preview:NO focus:NO];
    [t openPath:c preview:YES focus:NO];
    CHECK([t.openPaths isEqualToArray:(@[b, c])], "double-clicked tab stays: %s", t.openPaths.description.UTF8String);

    [t.editor insertText:@"!" replacementRange:NSMakeRange(NSNotFound, 0)];
    [t openPath:a preview:YES focus:NO];
    CHECK([t.openPaths isEqualToArray:(@[b, c, a])], "editing pins a preview tab: %s", t.openPaths.description.UTF8String);
    CHECK(t.dirtyCount == 1, "dirty count");
    [t openPath:c preview:YES focus:NO];
    CHECK([text(t.editor) isEqualToString:@"!three\n"] && t.editor.isDirty, "unsaved edits survive tab switches");
    [t.editor undo:nil];
    CHECK([text(t.editor) isEqualToString:@"three\n"], "undo history survives tab switches");
    [t.editor redo:nil];

    answer = NSAlertSecondButtonReturn;
    CHECK(![t closeActive] && t.tabCount == 3 && asked == 1, "cancel keeps the unsaved tab");
    answer = NSAlertThirdButtonReturn;
    CHECK([t closeActive] && [t.openPaths isEqualToArray:(@[b, a])], "don't-save closes it");
    CHECK([fileText(c, NSUTF8StringEncoding) isEqualToString:@"three\n"], "discarded edits not written");
    CHECK([t reopenClosed] && [t.currentPath isEqualToString:c] && !t.editor.isDirty, "reopen closed tab");

    [t selectTabAtIndex:0];
    CHECK([t.currentPath isEqualToString:b], "select tab 1");
    [t selectTabOffset:-1];
    CHECK([t.currentPath isEqualToString:c], "previous tab wraps around: %s", t.currentPath.UTF8String);

    NSDictionary *s = t.sessionState;
    NSArray *paths = t.openPaths;
    [t closeAllWithoutAsking];
    CHECK(t.tabCount == 0 && t.currentPath == nil, "close all");
    [t restoreSession:s];
    CHECK([t.openPaths isEqualToArray:paths] && [t.currentPath isEqualToString:c], "session restore");

    mkfile(dir, @"t3.txt", @"changed on disk\n");
    [t checkExternalChanges];
    CHECK([text(t.editor) isEqualToString:@"changed on disk\n"], "unmodified tab reloads after external change");
    [t.editor insertText:@"x" replacementRange:NSMakeRange(NSNotFound, 0)];
    mkfile(dir, @"t3.txt", @"changed again, longer\n");
    [t checkExternalChanges];
    CHECK([text(t.editor) hasPrefix:@"x"], "modified tab is not clobbered by external change");
    answer = NSAlertSecondButtonReturn;
    CHECK(![t save], "save asks before overwriting an externally changed file");
    answer = NSAlertFirstButtonReturn;
    CHECK([t save] && [fileText(c, NSUTF8StringEncoding) hasPrefix:@"x"], "overwrite when confirmed");

    // draw the pane (tab strip with dirty / preview / duplicate-name tabs) into a bitmap
    mkfile([dir stringByAppendingPathComponent:@"sub"], @"t1.txt", @"dup\n");
    [t openPath:[dir stringByAppendingPathComponent:@"sub/t1.txt"] preview:YES focus:NO];
    [t.editor insertText:@"d" replacementRange:NSMakeRange(NSNotFound, 0)];
    NSBitmapImageRep *rep = [t.view bitmapImageRepForCachingDisplayInRect:t.view.bounds];
    [t.view cacheDisplayInRect:t.view.bounds toBitmapImageRep:rep];
    CHECK(rep.pixelsWide > 0, "draw pane with tabs");

    answer = NSAlertThirdButtonReturn;
    CHECK([t closePathsWithin:dir] && t.tabCount == 0, "closePathsWithin closes every tab under a folder");
    [t.view cacheDisplayInRect:t.view.bounds toBitmapImageRep:rep];
}

static BOOL spinUntil(BOOL (^cond)(void), NSTimeInterval timeout) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!cond() && end.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    return cond();
}

static id findView(NSView *root, Class cls) {
    if ([root isKindOfClass:cls]) return root;
    for (NSView *v in root.subviews) { id f = findView(v, cls); if (f) return f; }
    return nil;
}

static ContentController *offscreenController(NSWindow **keep) {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1000, 700) styleMask:NSWindowStyleMaskTitled
                                                backing:NSBackingStoreBuffered defer:YES];
    ContentController *t = [ContentController new];
    t.view.frame = w.contentView.bounds;
    w.contentView = t.view;
    *keep = w;
    return t;
}

static void markdownPreview(NSString *dir) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"markdownLayout"];
    NSWindow *w; ContentController *t = offscreenController(&w);
    t.alertHandler = ^NSModalResponse(NSAlert *a) { return NSAlertThirdButtonReturn; };
    NSString *md = [dir stringByAppendingPathComponent:@"md"];
    [NSFileManager.defaultManager createDirectoryAtPath:md withIntermediateDirectories:YES attributes:nil error:nil];
    NSBitmapImageRep *png = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:40 pixelsHigh:20 bitsPerSample:8
        samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [[png representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[md stringByAppendingPathComponent:@"pic.png"] atomically:YES];
    mkfile(md, @"other.md", @"# Other\n\n## Sec\n\nbody\n");
    NSString *readme = mkfile(md, @"README.md",
        @"# Title\n\nSome **bold** and [jump](#second) and [other](other.md#sec).\n\n![pic](pic.png)\n\n"
        @"```py\ndef f(): return 1\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n- [x] done\n- [ ] todo\n\n"
        @"filler\n\nfiller\n\nfiller\n\nfiller\n\nfiller\n\nfiller\n\nfiller\n\nfiller\n\nfiller\n\nfiller\n\nfiller\n\nfiller\n\n"
        @"filler\n\nfiller\n\nfiller\n\nfiller\n\nfiller\n\nfiller\n\nfiller\n\nfiller\n\nfiller\n\nfiller\n\nfiller\n\nfiller\n\n"
        @"## Second\n\nend\n");

    [t openPath:readme preview:NO focus:NO];
    MarkdownPreview *mv = findView(t.view, MarkdownPreview.class);
    CHECK(t.activeIsMarkup && t.activeMarkupLayout == MarkupPreview && mv, "README.md opens rendered by default");
    NSTextStorage *ts = mv.textView.textStorage;
    NSString *s = ts.string;
    CHECK([s hasPrefix:@"Title"] && [s containsString:@"Some bold and jump and other."] && ![s containsString:@"**"], "markdown rendered: %s",
          [s substringToIndex:MIN((NSUInteger)80, s.length)].UTF8String);
    NSFont *h1 = [ts attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
    CHECK(h1.pointSize >= 24, "heading is large (%.0f)", h1.pointSize);
    NSUInteger at = [s rangeOfString:@"bold"].location;
    CHECK(at != NSNotFound && ([[ts attribute:NSFontAttributeName atIndex:at effectiveRange:NULL] fontDescriptor].symbolicTraits & NSFontDescriptorTraitBold), "bold");
    NSUInteger att = [s rangeOfString:@"\uFFFC"].location;
    NSTextAttachment *a = att != NSNotFound ? [ts attribute:NSAttachmentAttributeName atIndex:att effectiveRange:NULL] : nil;
    CHECK(a.image && a.bounds.size.width == 40, "local image attached (%.0f)", a.bounds.size.width);
    NSUInteger code = [s rangeOfString:@"def f()"].location;
    NSParagraphStyle *cps = code != NSNotFound ? [ts attribute:NSParagraphStyleAttributeName atIndex:code effectiveRange:NULL] : nil;
    CHECK(cps.textBlocks.count == 1 && cps.textBlocks[0].backgroundColor, "code block box");
    NSColor *kw = code != NSNotFound ? [ts attribute:NSForegroundColorAttributeName atIndex:code effectiveRange:NULL] : nil;
    CHECK([kw isEqual:HLColor(TokKeyword)], "python keyword highlighted");
    // Layout, not just attributes: short headings / code lines must stay on one line (boxes used to collapse to 1 glyph wide).
    NSLayoutManager *lm = mv.textView.layoutManager;
    [lm ensureLayoutForTextContainer:mv.textView.textContainer];
    for (NSString *frag in @[@"Title", @"def f(): return 1", @"Second"]) {
        NSRange r = [s rangeOfString:frag];
        __block NSUInteger lines = 0;
        if (r.location != NSNotFound)
            [lm enumerateLineFragmentsForGlyphRange:[lm glyphRangeForCharacterRange:r actualCharacterRange:NULL]
                                         usingBlock:^(NSRect a, NSRect u, NSTextContainer *c, NSRange g, BOOL *st) { lines++; }];
        CHECK(lines == 1, "\"%s\" laid out on one line (got %lu)", frag.UTF8String, (unsigned long)lines);
    }
    NSUInteger cell = [s rangeOfString:@"\n1\n"].location;
    NSParagraphStyle *tps = cell != NSNotFound ? [ts attribute:NSParagraphStyleAttributeName atIndex:cell + 1 effectiveRange:NULL] : nil;
    CHECK([tps.textBlocks.lastObject isKindOfClass:NSTextTableBlock.class], "table cell");
    BOOL found = [mv scrollToAnchor:@"second"];             // must work right after rendering, before any display pass
    CHECK(found && mv.textView.visibleRect.origin.y > 0, "anchor link scrolls (found=%d anchors=%s y=%.0f tv=%s preview=%s)", found,
          mv.renderer.anchors.description.UTF8String, mv.textView.visibleRect.origin.y,
          NSStringFromRect(mv.textView.frame).UTF8String, NSStringFromRect(mv.frame).UTF8String);
    [mv textView:mv.textView clickedOnLink:@"other.md#sec" atIndex:0];
    CHECK([t.currentPath hasSuffix:@"other.md"] && t.tabCount == 2, "relative .md link opens a tab: %s", t.currentPath.UTF8String);

    [t openPath:readme preview:NO focus:NO];
    t.activeMarkupLayout = MarkupSplit;
    mv = findView(t.view, MarkdownPreview.class);
    CHECK(mv && findView(t.view, TextEditorView.class) && [NSUserDefaults.standardUserDefaults integerForKey:@"markdownLayout"] == MarkupSplit,
          "split shows editor + preview and is remembered");
    [t.editor moveCaretTo:t.editor.contentLength extend:NO];
    [t.editor insertText:@"\nLIVE EDIT\n" replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK(spinUntil(^BOOL { return [mv.textView.string containsString:@"LIVE EDIT"]; }, 3), "preview updates while typing");

    NSMutableString *longMd = [NSMutableString string];
    for (int i = 0; i < 300; i++) [longMd appendFormat:@"Paragraph %d\n\n", i];
    NSString *lp = mkfile(md, @"long.md", longMd);
    [t openPath:lp preview:NO focus:NO];
    MarkdownPreview *lv = findView(t.view, MarkdownPreview.class);
    CHECK(lv && lv != mv && mv.window == nil, "background tab's preview is released");
    [t.editor gotoLine:301];                                     // "Paragraph 150" is on line 301
    NSRange vis = [lv.textView.layoutManager characterRangeForGlyphRange:
                   [lv.textView.layoutManager glyphRangeForBoundingRect:lv.textView.visibleRect inTextContainer:lv.textView.textContainer] actualGlyphRange:NULL];
    NSString *seen = vis.length ? [lv.textView.string substringWithRange:vis] : @"";
    CHECK([seen containsString:@"Paragraph 15"], "split preview follows the editor scroll: %s",
          [seen substringToIndex:MIN((NSUInteger)40, seen.length)].UTF8String);

    t.activeMarkupLayout = MarkupSource;
    CHECK(!findView(t.view, MarkdownPreview.class), "source-only frees the preview");
    [t closeAllWithoutAsking];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"markdownLayout"];
}

static void minimap(NSString *dir) {
    NSWindow *w; ContentController *t = offscreenController(&w);
    NSMutableString *src = [NSMutableString string];
    for (int i = 0; i < 2000; i++) [src appendFormat:@"int value_%d = %d; // comment %d\n", i, i * 7, i];
    NSString *p = mkfile(dir, @"map.c", src);
    [t openPath:p preview:NO focus:NO];
    TextEditorView *ed = t.editor;
    CHECK(ed.showsMinimap && ed.minimapWidth > 0, "minimap shown by default");
    NSRect m = ed.minimapRect;
    CHECK(NSMaxX(m) <= ed.bounds.size.width && m.size.width >= 60, "minimap sits at the right edge (%s)", NSStringFromRect(m).UTF8String);

    // drawing produces coloured blocks inside the minimap, background below the last line in a short file
    NSBitmapImageRep *rep = [ed bitmapImageRepForCachingDisplayInRect:ed.bounds];
    [ed cacheDisplayInRect:ed.bounds toBitmapImageRep:rep];
    CGFloat scale = rep.pixelsWide / ed.bounds.size.width;
    NSColor *bg = [rep colorAtX:(NSInteger)((NSMinX(m) + 3) * scale) y:(NSInteger)(ed.bounds.size.height * scale - 4)];
    NSUInteger inked = 0;
    for (NSInteger y = 0; y < (NSInteger)(200 * scale); y += 2)
        for (NSInteger x = (NSInteger)((NSMinX(m) + 6) * scale); x < (NSInteger)((NSMinX(m) + 40) * scale); x += 2) {
            NSColor *c = [rep colorAtX:x y:y];
            if (fabs(c.redComponent - bg.redComponent) + fabs(c.greenComponent - bg.greenComponent) + fabs(c.blueComponent - bg.blueComponent) > 0.08) inked++;
        }
    CHECK(inked > 50, "minimap draws code blocks (%lu inked samples)", (unsigned long)inked);

    // slider follows the editor
    CHECK(ed.minimapSliderRect.origin.y == 0, "slider at top");
    ed.scrollY = ed.maxScrollY;
    CHECK(fabs(NSMaxY(ed.minimapSliderRect) - ed.bounds.size.height) < 1, "slider at bottom when scrolled to the end");
    // click in the minimap jumps there; dragging the slider scrolls proportionally
    ed.scrollY = 0;
    CGFloat targetY = m.size.height * 0.75;
    CHECK([ed minimapPressAt:NSMakePoint(NSMidX(m), targetY)], "press inside minimap handled");
    CGFloat clickedLine = targetY / 2;                                  // 2 pt per line, map not scrolled yet
    CGFloat centreLine = (ed.scrollY + ed.bounds.size.height / 2 - 4) / ed->_lineHeight;
    CHECK(fabs(centreLine - clickedLine) < 2, "click centres the line under the cursor (line %.0f, wanted %.0f)", centreLine, clickedLine);
    NSRect s = ed.minimapSliderRect;
    [ed minimapPressAt:NSMakePoint(NSMidX(s), NSMidY(s))];
    [ed minimapDragTo:NSMakePoint(NSMidX(s), NSMidY(s) - m.size.height)];
    CHECK(ed.scrollY == 0, "dragging the slider to the top scrolls to the top (%.0f)", ed.scrollY);
    CHECK(![ed minimapPressAt:NSMakePoint(40, 40)], "presses in the text area are not taken");

    // caret should not land under the minimap
    [ed moveCaretTo:[ed->_buf lineEnd:5] extend:NO];
    CHECK(ed.rightInset == ed.minimapWidth + [CanvasView indicatorWidth], "text area excludes the minimap");

    // toggling
    t.showsMinimap = NO;
    CHECK(!ed.showsMinimap && ed.minimapWidth == 0 && ![ed minimapPressAt:NSMakePoint(NSMidX(m), 10)], "minimap can be turned off");
    t.showsMinimap = YES;

    // cost: 300 scroll frames over a 100k-line file
    NSMutableString *big = [NSMutableString string];
    for (int i = 0; i < 100000; i++) [big appendFormat:@"    if (x_%d > %d) { call(\"str\", %d); } // c\n", i, i, i];
    [t openPath:mkfile(dir, @"big.c", big) preview:NO focus:NO];
    ed = t.editor;
    NSBitmapImageRep *r2 = [ed bitmapImageRepForCachingDisplayInRect:ed.bounds];
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    for (int f = 0; f < 300; f++) {
        ed.scrollY = ed.maxScrollY * f / 300.0;
        [ed cacheDisplayInRect:ed.minimapRect toBitmapImageRep:r2];
    }
    double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000 / 300;
    printf("   minimap frame on a 100k-line file: %.2f ms\n", ms);
    CHECK(ms < 16, "minimap draws within a frame (%.2f ms)", ms);
    [t closeAllWithoutAsking];
}

static NSUInteger whitePixels(NSImage *img) {
    NSBitmapImageRep *r = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)img.size.width * 2
        pixelsHigh:(NSInteger)img.size.height * 2 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:r];
    [img drawInRect:NSMakeRect(0, 0, r.pixelsWide, r.pixelsHigh)];
    [NSGraphicsContext restoreGraphicsState];
    NSUInteger n = 0;
    for (NSInteger y = 0; y < r.pixelsHigh; y++) for (NSInteger x = 0; x < r.pixelsWide; x++) {
        NSColor *p = [r colorAtX:x y:y];
        if (p.alphaComponent > 0.5 && p.redComponent > 0.85 && p.greenComponent > 0.85 && p.blueComponent > 0.85) n++;
    }
    return n;
}

// The four problems reported on better-sqlite3's README (a trimmed copy, so the test needs no network).
static void readmeIssues(NSString *dir) {
    NSWindow *w; ContentController *t = offscreenController(&w);
    t.alertHandler = ^NSModalResponse(NSAlert *a) { return NSAlertThirdButtonReturn; };
    NSString *d = [dir stringByAppendingPathComponent:@"bsq"];
    [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    // GitHub's workflow badge: shapes plus <text> that the system SVG renderer drops
    NSString *svg = @"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"104\" height=\"20\"><g fill=\"none\">"
        @"<g font-family=\"'DejaVu Sans',Verdana,sans-serif\" font-size=\"11\"><path d=\"M0,0 L54,0 L54,20 L0,20 Z\" fill=\"#24292E\"/>"
        @"<text fill=\"#010101\" fill-opacity=\".3\"><tspan x=\"22\" y=\"15\">build</tspan></text>"
        @"<text fill=\"#FFFFFF\"><tspan x=\"22\" y=\"14\">build</tspan></text></g>"
        @"<g transform=\"translate(54)\" font-family=\"'DejaVu Sans',Verdana,sans-serif\" font-size=\"11\">"
        @"<path d=\"M0 0h50v20H0V0z\" fill=\"#28A745\"/><text fill=\"#FFFFFF\"><tspan x=\"4\" y=\"14\">passing</tspan></text></g></g></svg>";
    [[svg dataUsingEncoding:NSUTF8StringEncoding] writeToFile:[d stringByAppendingPathComponent:@"badge.svg"] atomically:YES];
    mkfile(d, @"LICENSE", @"MIT License\n");
    NSString *readme = mkfile(d, @"README.md",
        @"# better-sqlite3 [![Build Status](badge.svg)](https://example.com)\n\n"
        @"|   |select 1 row &nbsp;`get()`&nbsp;|select 100 rows &nbsp;&nbsp;`all()`&nbsp;&nbsp;|\n|---|---|---|\n|a|1x|2x|\n\n"
        @"- [API documentation](./docs/api.md)\n\n# License\n\n[MIT](./LICENSE)\n");

    // 1) a plain-text tab next to it: nothing may paint outside its own frame (the tab bar is just above)
    NSString *plain = mkfile(d, @"notes.txt", @"plain\n");
    [t openPath:plain preview:NO focus:NO];
    if (@available(macOS 14.0, *)) {
        CHECK(t.editor.clipsToBounds && t.view.clipsToBounds, "editor and pane clip to their bounds");
        CHECK(((NSView *)findView(t.view, TabBarView.class)).clipsToBounds, "tab bar clips to its bounds");
    }
    NSView *tabs = findView(t.view, TabBarView.class);
    CHECK(tabs && !tabs.hidden && NSMinY(t.editor.frame) >= NSMaxY(tabs.frame), "tab bar visible above a plain-text editor");

    [t openPath:readme preview:YES focus:NO];
    MarkdownPreview *mv = findView(t.view, MarkdownPreview.class);
    NSTextStorage *ts = mv.textView.textStorage;
    NSString *s = ts.string;
    // 2) badge text drawn
    NSUInteger att = [s rangeOfString:@"\uFFFC"].location;
    NSTextAttachment *a = att != NSNotFound ? [ts attribute:NSAttachmentAttributeName atIndex:att effectiveRange:NULL] : nil;
    NSUInteger white = a.image ? whitePixels(a.image) : 0;
    CHECK(white > 250, "badge shows its text (%lu white pixels; the system renderer gives ~0)", (unsigned long)white);
    // 3) `get()` grey box is just the code, no padding
    CHECK([s rangeOfString:@"\u2009"].location == NSNotFound, "no padding characters around inline code");
    NSUInteger g = [s rangeOfString:@"get()"].location;
    NSRange grey = {0, 0};
    if (g != NSNotFound) [ts attribute:NSBackgroundColorAttributeName atIndex:g effectiveRange:&grey];
    CHECK(grey.length == 5, "grey background covers only `get()` (%lu chars)", (unsigned long)grey.length);
    // 4a) missing link target is shown as such, clicking explains instead of doing nothing
    NSUInteger api = [s rangeOfString:@"API documentation"].location;
    CHECK(api != NSNotFound && [ts attribute:NSStrikethroughStyleAttributeName atIndex:api effectiveRange:NULL], "link to a missing file is marked");
    [mv.textView activateLinkAtIndex:api];
    spinUntil(^BOOL { return [t.statusText containsString:@"no longer exists"]; }, 2);
    CHECK([t.statusText containsString:@"docs/api.md"] && t.tabCount == 2, "clicking it says the file is missing: %s", t.statusText.UTF8String);
    // 4b) existing link: real mouse down/up on the text view opens a new tab and keeps README
    NSUInteger mit = [s rangeOfString:@"MIT" options:NSBackwardsSearch].location;
    NSLayoutManager *lm = mv.textView.layoutManager;
    [lm ensureLayoutForTextContainer:mv.textView.textContainer];
    NSRect gr = [lm boundingRectForGlyphRange:[lm glyphRangeForCharacterRange:NSMakeRange(mit, 3) actualCharacterRange:NULL] inTextContainer:mv.textView.textContainer];
    NSPoint pt = NSMakePoint(NSMidX(gr) + mv.textView.textContainerOrigin.x, NSMidY(gr) + mv.textView.textContainerOrigin.y);
    CHECK([mv.textView linkIndexAtPoint:pt] != NSNotFound, "hit-testing finds the link");
    NSPoint wp = [mv.textView convertPoint:pt toView:nil];
    NSEvent *(^ev)(NSEventType) = ^NSEvent *(NSEventType type) {
        return [NSEvent mouseEventWithType:type location:wp modifierFlags:0 timestamp:0 windowNumber:w.windowNumber context:nil
                               eventNumber:0 clickCount:1 pressure:type == NSEventTypeLeftMouseDown];
    };
    CHECK([mv.textView acceptsFirstMouse:ev(NSEventTypeLeftMouseDown)], "first click into an inactive window follows links");
    [mv.textView mouseDown:ev(NSEventTypeLeftMouseDown)];
    [mv.textView mouseUp:ev(NSEventTypeLeftMouseUp)];
    CHECK(spinUntil(^BOOL { return [t.currentPath hasSuffix:@"LICENSE"]; }, 2), "click on [MIT](./LICENSE) opens it: %s", t.currentPath.UTF8String);
    CHECK(t.tabCount == 3 && [t.openPaths containsObject:readme], "in a new tab, README stays open (%s)",
          [[t.openPaths valueForKey:@"lastPathComponent"] componentsJoinedByString:@","].UTF8String);
    [t openPath:plain preview:YES focus:NO];
    CHECK([t.openPaths containsObject:readme], "README was pinned, so another single click doesn't replace it");
    [t closeAllWithoutAsking];
}

#pragma mark Image / PDF viewers

// w×h image, red top-left quadrant, blue elsewhere.
static void writeQuadrantImage(NSString *path, NSInteger w, NSInteger h, NSBitmapImageFileType type) {
    NSBitmapImageRep *r = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h bitsPerSample:8
        samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:r];
    [NSColor.blueColor setFill]; NSRectFill(NSMakeRect(0, 0, w, h));
    [NSColor.redColor setFill]; NSRectFill(NSMakeRect(0, h / 2, w / 2, h / 2));         // bottom-left origin: top-left quadrant
    [NSGraphicsContext restoreGraphicsState];
    [[r representationUsingType:type properties:@{NSImageCompressionFactor: @0.8}] writeToFile:path atomically:YES];
}

static void writePDF(NSString *path, NSArray<NSString *> *pages, NSString *password) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (password) { info[(id)kCGPDFContextUserPassword] = password; info[(id)kCGPDFContextOwnerPassword] = password; }
    CGRect box = CGRectMake(0, 0, 612, 792);
    CGContextRef pdf = CGPDFContextCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], &box, (__bridge CFDictionaryRef)info);
    for (NSString *t in pages) {
        CGPDFContextBeginPage(pdf, NULL);
        NSGraphicsContext *g = [NSGraphicsContext graphicsContextWithCGContext:pdf flipped:NO];
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = g;
        [t drawAtPoint:NSMakePoint(72, 700) withAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:24]}];
        [NSGraphicsContext restoreGraphicsState];
        CGPDFContextEndPage(pdf);
    }
    CGPDFContextClose(pdf);
    CGContextRelease(pdf);
}

static NSColor *pixelAt(NSView *v, NSPoint p) {
    NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
    [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
    CGFloat s = rep.pixelsWide / v.bounds.size.width;
    return [[rep colorAtX:(NSInteger)(p.x * s) y:(NSInteger)(p.y * s)] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
}
static BOOL isRed(NSColor *c) { return c.redComponent > 0.7 && c.blueComponent < 0.4; }
static BOOL isBlue(NSColor *c) { return c.blueComponent > 0.7 && c.redComponent < 0.3; }

static void imageViewer(NSString *dir) {
    NSWindow *w; ContentController *t = offscreenController(&w);
    NSString *png = [dir stringByAppendingPathComponent:@"quad.png"];
    writeQuadrantImage(png, 400, 200, NSBitmapImageFileTypePNG);
    [t openPath:png preview:NO focus:NO];
    ImagePreviewView *iv = t.activeImage;
    CHECK(iv && spinUntil(^BOOL { return iv.decodedSize.width > 0; }, 5), "image opens");
    CHECK(iv.fitsWindow && iv.zoomPercent == 100, "small image fits at 100%% (%.0f)", iv.zoomPercent);
    CHECK(iv.toolsView.superview != nil, "zoom tools in the status bar");
    NSRect r = iv.imageRect;
    CHECK(isRed(pixelAt(iv, NSMakePoint(NSMinX(r) + 20, NSMinY(r) + 20))) && isBlue(pixelAt(iv, NSMakePoint(NSMaxX(r) - 20, NSMinY(r) + 20))),
          "drawn upright (red top-left)");

    [t zoomIn];
    CHECK(!iv.fitsWindow && iv.zoomPercent == 125, "⌘+ steps to 125%% (%.0f)", iv.zoomPercent);
    [t zoomIn]; [t zoomIn];
    CHECK(iv.zoomPercent == 200 && iv.imageRect.size.width == 800, "200%% draws twice as large (%.0f wide)", iv.imageRect.size.width);
    [iv setZoom:4 around:NSMakePoint(NSMidX(iv.bounds), NSMidY(iv.bounds))];
    NSPoint before = iv.imageRect.origin;                  // 400%: 1600×800, larger than the view both ways
    [iv panBy:NSMakeSize(-50, -30)];
    CHECK(iv.imageRect.origin.x == before.x - 50 && iv.imageRect.origin.y == before.y - 30, "dragging pans the image");
    NSPoint corner = NSMakePoint(NSMinX(iv.bounds) + 100, NSMinY(iv.bounds) + 100);
    NSRect r0 = iv.imageRect;
    CGFloat k0 = r0.size.width / 400;
    NSPoint imgPt = NSMakePoint((corner.x - r0.origin.x) / k0, (corner.y - r0.origin.y) / k0);
    [iv setZoom:6 around:corner];
    NSRect r1 = iv.imageRect;
    CHECK(fabs((corner.x - r1.origin.x) / 6 - imgPt.x) < 1 && fabs((corner.y - r1.origin.y) / 6 - imgPt.y) < 1,
          "pinch / ⌘-scroll zoom keeps the point under the cursor");
    [t zoomReset];
    CHECK(iv.fitsWindow, "⌘0 back to fit");

    [t rotate:1];
    r = iv.imageRect;
    CHECK(iv.rotation == 1 && r.size.width == 200 && r.size.height == 400, "rotated: portrait %s", NSStringFromRect(r).UTF8String);
    CHECK(isRed(pixelAt(iv, NSMakePoint(NSMaxX(r) - 20, NSMinY(r) + 20))) && isBlue(pixelAt(iv, NSMakePoint(NSMinX(r) + 20, NSMinY(r) + 20))),
          "rotating right moves the red corner to the top-right");
    [t rotate:-1];
    CHECK(iv.rotation == 0 && [iv.info containsString:@"400 × 200"], "rotate back: %s", iv.info.UTF8String);

    NSPasteboard *pb = [NSPasteboard pasteboardWithUniqueName];
    [iv writeToPasteboard:pb];
    CHECK([pb dataForType:NSPasteboardTypePNG].length > 0 && [pb stringForType:NSPasteboardTypeFileURL].length, "copy puts the file and image data on the pasteboard");
    [pb releaseGlobally];

    // a big photo: fit decodes small, 100% decodes (nearly) full size, zooming out frees it again
    NSString *jpg = [dir stringByAppendingPathComponent:@"big.jpg"];
    writeQuadrantImage(jpg, 4000, 3000, NSBitmapImageFileTypeJPEG);
    [t openPath:jpg preview:NO focus:NO];
    iv = t.activeImage;
    spinUntil(^BOOL { return iv.decodedSize.width > 0 && [iv.info containsString:@"4000"]; }, 5);
    CGFloat fitW = iv.decodedSize.width;
    CHECK(fitW > 0 && fitW < 2500, "fitted photo decoded at screen size (%.0f px)", fitW);
    [t zoomActualSize];
    CHECK(spinUntil(^BOOL { return iv.decodedSize.width >= 3900; }, 8), "100%% re-decodes at full size (%.0f px)", iv.decodedSize.width);
    [t zoomReset];
    CHECK(spinUntil(^BOOL { return iv.decodedSize.width < 2500; }, 5), "fit again releases the big decode (%.0f px)", iv.decodedSize.width);

    // animated GIF
    NSString *gif = [dir stringByAppendingPathComponent:@"anim.gif"];
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:gif], CFSTR("com.compuserve.gif"), 3, NULL);
    CGImageDestinationSetProperties(dst, (__bridge CFDictionaryRef)@{(id)kCGImagePropertyGIFDictionary: @{(id)kCGImagePropertyGIFLoopCount: @0}});
    for (NSColor *c in @[NSColor.redColor, NSColor.greenColor, NSColor.blueColor]) {
        NSImage *f = [NSImage imageWithSize:NSMakeSize(40, 40) flipped:NO drawingHandler:^BOOL(NSRect rr) { [c setFill]; NSRectFill(rr); return YES; }];
        CGImageRef cg = [f CGImageForProposedRect:NULL context:nil hints:nil];
        CGImageDestinationAddImage(dst, cg, (__bridge CFDictionaryRef)@{(id)kCGImagePropertyGIFDictionary: @{(id)kCGImagePropertyGIFDelayTime: @0.05}});
    }
    CGImageDestinationFinalize(dst); CFRelease(dst);
    [t openPath:gif preview:NO focus:NO];
    iv = t.activeImage;
    spinUntil(^BOOL { return iv.frameCount > 0; }, 5);
    __block NSMutableSet *seen = [NSMutableSet set];
    spinUntil(^BOOL {
        NSRect rr = iv.imageRect;
        NSColor *c = pixelAt(iv, NSMakePoint(NSMidX(rr), NSMidY(rr)));
        [seen addObject:@(c.redComponent > 0.5 ? 0 : c.greenComponent > 0.3 ? 1 : 2)];
        return seen.count >= 2;
    }, 3);
    CHECK(iv.frameCount == 3 && seen.count >= 2, "GIF animates (%lu frames, saw %lu colours)", (unsigned long)iv.frameCount, (unsigned long)seen.count);
    [t closeAllWithoutAsking];
}

static void svgAndTypeScript(NSString *dir) {
    NSWindow *w; ContentController *t = offscreenController(&w);
    NSString *svg = mkfile(dir, @"logo.svg", @"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"200\" height=\"100\">"
                           @"<rect width=\"200\" height=\"50\" fill=\"#ff0000\"/><rect y=\"50\" width=\"200\" height=\"50\" fill=\"#0000ff\"/>"
                           @"<text x=\"10\" y=\"30\" fill=\"#fff\">Hi</text></svg>");
    [t openPath:svg preview:NO focus:NO];
    ImagePreviewView *iv = t.activeImage;
    CHECK(iv && iv.isVector && spinUntil(^BOOL { return iv.decodedSize.width > 0; }, 5), "SVG opens in the image viewer");
    CHECK([iv.info containsString:@"200 × 100"] && [iv.info containsString:@"SVG"], "SVG size from the file: %s", iv.info.UTF8String);
    NSRect r = iv.imageRect;
    CHECK(isRed(pixelAt(iv, NSMakePoint(NSMidX(r), NSMinY(r) + 10))) && isBlue(pixelAt(iv, NSMakePoint(NSMidX(r), NSMaxY(r) - 10))),
          "SVG drawn upright (red on top)");
    [iv setZoom:8 around:NSMakePoint(NSMidX(iv.bounds), NSMidY(iv.bounds))];
    CHECK(spinUntil(^BOOL { return iv.decodedSize.width >= 1600; }, 5), "zooming in re-renders the SVG sharp (%.0f px wide)", iv.decodedSize.width);
    NSPasteboard *pb = [NSPasteboard pasteboardWithUniqueName];
    [iv writeToPasteboard:pb];
    NSBitmapImageRep *png = [NSBitmapImageRep imageRepWithData:[pb dataForType:NSPasteboardTypePNG]];
    CHECK(png.pixelsWide == 400, "copying an SVG gives a @2x PNG (%ld px)", (long)png.pixelsWide);
    [pb releaseGlobally];

    // a 14-pt icon with only a viewBox, drawn in currentColor (the kind that looked like nothing opened)
    w.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    NSString *icon = mkfile(dir, @"icon-small.svg", @"<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 14 14\" fill=\"none\">"
                            @"<rect x=\"1\" y=\"1\" width=\"12\" height=\"12\" fill=\"currentColor\"/></svg>");
    [t openPath:icon preview:NO focus:NO];
    iv = t.activeImage;
    CHECK(iv && spinUntil(^BOOL { return iv.decodedSize.width > 0; }, 5), "viewBox-only SVG opens");
    CHECK(iv.imageRect.size.width >= 300 && iv.fitsWindow, "small SVG icon is scaled up to fit (%.0f pt wide)", iv.imageRect.size.width);
    NSColor *ink = pixelAt(iv, NSMakePoint(NSMidX(iv.imageRect), NSMidY(iv.imageRect)));
    CHECK(ink.brightnessComponent > 0.8, "currentColor follows the text colour, not black on dark (brightness %.2f)", ink.brightnessComponent);
    w.appearance = nil;

    NSString *bad = mkfile(dir, @"broken.svg", @"<svg this is not finished");
    [t openPath:bad preview:NO focus:NO];
    CHECK(spinUntil(^BOOL { return t.editor != nil; }, 5) && [t.currentPath isEqual:bad], "an SVG that can't be drawn opens as source");

    NSString *ts = mkfile(dir, @"db.ts", @"import { Database } from './x';\nexport const db = new Database();\n");
    [t openPath:ts preview:NO focus:NO];
    CHECK(t.editor && [t.statusText containsString:@"Ln 1"], ".ts opens in the editor, not as MPEG-2 video");
    [t closeAllWithoutAsking];
}

static void pdfViewer(NSString *dir) {
    NSWindow *w; ContentController *t = offscreenController(&w);
    NSString *pdf = [dir stringByAppendingPathComponent:@"doc.pdf"];
    writePDF(pdf, @[@"Alpha one", @"Bravo two", @"Charlie three needle"], nil);
    [t openPath:pdf preview:NO focus:NO];
    PDFPreview *pv = t.activePDF;
    CHECK(pv && pv.pageCount == 3, "PDF opens in the PDF viewer (%lu pages)", (unsigned long)pv.pageCount);
    CHECK([t.statusText containsString:@"Page 1 of 3"], "status shows the page: %s", t.statusText.UTF8String);
    CHECK(pv.toolsView.superview != nil, "PDF tools in the status bar");
    [pv nextPage];
    CHECK(pv.currentPage == 1, "next page");
    [t goToPage:2];
    CHECK(pv.currentPage == 2 && [t.statusText containsString:@"Page 3 of 3"], "go to page 3: %s", t.statusText.UTF8String);
    [t goToPage:0];

    CGFloat z0 = pv.zoomPercent;
    [t zoomIn];
    CHECK(pv.zoomPercent > z0, "⌘+ zooms the PDF (%.0f → %.0f)", z0, pv.zoomPercent);
    [t zoomOut]; [t zoomOut];
    CHECK(pv.zoomPercent < z0, "⌘- zooms out (%.0f)", pv.zoomPercent);
    [t zoomActualSize];
    CHECK(pv.zoomPercent == 100, "actual size = 100%%");
    [pv ftZoomToFitPage];
    CHECK(pv.zoomPercent > 0 && pv.zoomPercent < 100, "fit whole page (%.0f%%)", pv.zoomPercent);
    [t zoomReset];

    CHECK([t findInActive:@"NEEDLE" backward:NO] && pv.currentPage == 2, "find in the PDF text jumps to the page with the match");
    CHECK(![t findInActive:@"no such text" backward:NO], "find reports no match");
    [t showFindBar];
    NSButton *replaceAll = nil;
    NSMutableArray *q = [NSMutableArray arrayWithObject:t.view];
    while (q.count) { NSView *v = q[0]; [q removeObjectAtIndex:0]; if ([v isKindOfClass:NSButton.class] && [[(NSButton *)v title] isEqualToString:@"Replace All"]) replaceAll = (id)v; [q addObjectsFromArray:v.subviews]; }
    CHECK(replaceAll && replaceAll.hidden, "PDF find bar has no replace");

    pv.showsThumbnails = YES;
    CHECK(findView(pv, PDFThumbnailView.class) != nil && pv.pdfView.frame.origin.x > 0, "thumbnail sidebar");
    pv.showsThumbnails = NO;
    CHECK(findView(pv, PDFThumbnailView.class) == nil, "thumbnails closed (and released)");
    pv.twoPages = YES;
    CHECK(pv.pdfView.displayMode == kPDFDisplayTwoUpContinuous, "two-page display");
    pv.twoPages = NO;
    [t rotate:1];
    CHECK([pv.pdfView.currentPage rotation] == 90, "rotate current page (view only)");
    CHECK([[NSData dataWithContentsOfFile:pdf] length] > 0 && [[PDFDocument alloc] initWithURL:[NSURL fileURLWithPath:pdf]].pageCount == 3 &&
          [[[PDFDocument alloc] initWithURL:[NSURL fileURLWithPath:pdf]] pageAtIndex:0].rotation == 0, "the file on disk is not rotated");

    // password-protected
    NSString *locked = [dir stringByAppendingPathComponent:@"locked.pdf"];
    writePDF(locked, @[@"Secret"], @"pw123");
    __block NSUInteger asked = 0;
    t.alertHandler = ^NSModalResponse(NSAlert *a) {
        asked++;
        if ([a.accessoryView isKindOfClass:NSSecureTextField.class]) [(NSTextField *)a.accessoryView setStringValue:asked == 1 ? @"wrong" : @"pw123"];
        return NSAlertFirstButtonReturn;
    };
    [t openPath:locked preview:NO focus:NO];
    CHECK(t.activePDF && !t.activePDF.isLocked && asked == 2, "asks for the password again after a wrong one, then opens (%lu prompts)", (unsigned long)asked);
    [t closeActive];
    t.alertHandler = ^NSModalResponse(NSAlert *a) { return NSAlertSecondButtonReturn; };
    [t openPath:locked preview:NO focus:NO];
    CHECK(t.activePDF == nil && t.tabCount >= 1, "cancelling the password shows a placeholder");
    [t closeAllWithoutAsking];
}

static void zoomOtherViews(NSString *dir) {
    NSWindow *w; ContentController *t = offscreenController(&w);
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSString *txt = mkfile(dir, @"z.txt", @"hello\n");
    [t openPath:txt preview:NO focus:NO];
    CGFloat f0 = t.editor.fontSize;
    [t zoomIn]; [t zoomIn];
    CHECK(t.editor.fontSize == f0 + 2 && [t.statusText containsString:@"font size"], "⌘+ grows the editor font (%.0f → %.0f)", f0, t.editor.fontSize);
    NSString *txt2 = mkfile(dir, @"z2.txt", @"x\n");
    [t openPath:txt2 preview:NO focus:NO];
    CHECK(t.editor.fontSize == f0 + 2, "new editors use the same size");
    [t zoomReset];
    CHECK(t.editor.fontSize == 13, "⌘0 back to the default size");

    NSString *md = mkfile(dir, @"z.md", @"# Heading\n\ntext\n");
    [t openPath:md preview:NO focus:NO];
    t.activeMarkupLayout = MarkupPreview;
    MarkdownPreview *mv = findView(t.view, MarkdownPreview.class);
    CGFloat h0 = [[mv.textView.textStorage attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL] pointSize];
    [t zoomIn]; [t zoomIn];
    CGFloat h1 = [[mv.textView.textStorage attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL] pointSize];
    CHECK(fabs(h1 - h0 * 1.2) < 0.5 && t.editor.fontSize == 13, "⌘+ in the Markdown preview scales the text, not the editor (%.1f → %.1f)", h0, h1);
    [t zoomReset];
    CHECK(fabs(mv.scale - 1) < 0.01, "⌘0 resets the preview");
    [t closeAllWithoutAsking];
    for (NSString *k in @[@"editorFontSize", @"markdownScale", @"htmlZoom", @"markdownLayout", @"pdfThumbnails"]) [ud removeObjectForKey:k];
}

#pragma mark Default apps (fake Launch Services: nothing on this Mac is changed)

static void defaultApps(NSString *dir) {
    NSMutableDictionary<NSString *, NSURL *> *ls = [NSMutableDictionary dictionary];       // uti → app
    // not ".app": Launch Services would register these fake apps and list them in Finder's "Open With"
    NSURL *vscode = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"Code.testapp"]];
    NSURL *textedit = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"TextEdit.testapp"]];
    NSURL *feather = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"Feather.testapp"]];
    for (NSURL *app in @[vscode, textedit, feather]) {          // minimal bundles so NSBundle can read their ids
        NSString *contents = [app.path stringByAppendingPathComponent:@"Contents"];
        [NSFileManager.defaultManager createDirectoryAtPath:contents withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *bid = app == feather ? @"test.feather" : [@"test." stringByAppendingString:app.lastPathComponent.stringByDeletingPathExtension];
        [@{@"CFBundleIdentifier": bid, @"CFBundlePackageType": @"APPL"} writeToFile:[contents stringByAppendingPathComponent:@"Info.plist"] atomically:YES];
    }
    FileTypeGroup *md = nil, *txt = nil;
    for (FileTypeGroup *g in DefaultApps.groups) { if ([g.key isEqual:@"markdown"]) md = g; if ([g.key isEqual:@"text"]) txt = g; }
    for (NSString *t in md.contentTypes) ls[t] = vscode;
    for (NSString *t in txt.contentTypes) ls[t] = textedit;
    NSUserDefaults *store = [[NSUserDefaults alloc] initWithSuiteName:@"feather.tests.defaultapps"];
    [store removePersistentDomainForName:@"feather.tests.defaultapps"];
    __block NSUInteger calls = 0;
    DefaultApps *(^make)(void) = ^DefaultApps *{
        DefaultApps *a = [DefaultApps new];
        a.featherBundleID = @"test.feather";
        a.featherURL = feather;
        a.store = store;
        a.lookup = ^NSURL *(NSString *uti) { return ls[uti]; };
        a.setHandler = ^(NSURL *app, NSString *uti, void (^done)(NSError *)) {
            calls++;
            ls[uti] = app;
            dispatch_async(dispatch_get_main_queue(), ^{ done(nil); });
        };
        return a;
    };
    DefaultApps *a = make();
    __block NSString *err = @"?";
    BOOL (^settled)(void) = ^BOOL { return ![err isEqual:@"?"]; };

    FileTypeGroup *tsGroup = nil, *codeGroup = nil;
    for (FileTypeGroup *g in DefaultApps.groups) {
        if ([g.extensions containsObject:@"ts"]) tsGroup = g;
        if ([g.key isEqual:@"code"]) codeGroup = g;
    }
    CHECK(md.contentTypes.count >= 1 && tsGroup && tsGroup != codeGroup,
          "groups resolve to content types; .ts (also MPEG-2 video) is its own opt-in group");
    CHECK(![a featherIsDefaultFor:md] && [[a currentDefaultName:md] isEqualToString:@"Code"], "current default shown: %s", [a currentDefaultName:md].UTF8String);

    [a setGroup:md toFeather:YES done:^(NSString *e) { err = e; }];
    spinUntil(settled, 2);
    CHECK(!err && [a featherIsDefaultFor:md] && [[a currentDefaultName:md] isEqualToString:@"Feather"], "Markdown now opens with Feather");
    CHECK([ls[txt.contentTypes.firstObject] isEqual:textedit], "other types untouched");
    NSUInteger before = calls;
    err = @"?";
    [a setGroup:md toFeather:YES done:^(NSString *e) { err = e; }];
    spinUntil(settled, 2);
    CHECK(calls == before, "setting it again changes nothing");

    a = make();                                                  // a later launch: the previous app is remembered
    err = @"?";
    [a setGroup:md toFeather:NO done:^(NSString *e) { err = e; }];
    spinUntil(settled, 2);
    CHECK(!err && [[NSBundle bundleWithURL:ls[md.contentTypes.firstObject]].bundleIdentifier isEqualToString:@"test.Code"], "unticking gives it back to the previous app (%s)", ls[md.contentTypes.firstObject].path.UTF8String);

    err = @"?";
    [a setGroup:txt toFeather:YES done:^(NSString *e) { err = e; }];
    spinUntil(settled, 2);
    [NSFileManager.defaultManager removeItemAtURL:textedit error:nil];      // previous app was deleted meanwhile
    err = @"?";
    [a setGroup:txt toFeather:NO done:^(NSString *e) { err = e; }];
    spinUntil(settled, 2);
    CHECK([err containsString:@"Get Info"] && [a featherIsDefaultFor:txt], "missing previous app is reported: %s", err.UTF8String);

    for (NSString *t in md.contentTypes) ls[t] = vscode;
    DefaultAppsPanel *p = [DefaultAppsPanel new];
    p.apps = make();
    [p buildSheet];
    NSUInteger mdIndex = [DefaultApps.groups indexOfObjectPassingTest:^BOOL(FileTypeGroup *g, NSUInteger i, BOOL *s) { return [g.key isEqual:@"markdown"]; }];
    CHECK(p.checkboxes.count == DefaultApps.groups.count && p.checkboxes[mdIndex].state == NSControlStateValueOff, "sheet reflects current defaults");
    p.checkboxes[mdIndex].state = NSControlStateValueOn;
    __block BOOL finished = NO;
    [p applyThen:^(NSString *e) { finished = YES; }];
    spinUntil(^BOOL { return finished; }, 2);
    CHECK([ls[md.contentTypes.firstObject] isEqual:feather], "applying the sheet sets the ticked group");

    // .html belongs to the default browser on macOS: shown, explained, never attempted
    NSUInteger htmlIndex = [DefaultApps.groups indexOfObjectPassingTest:^BOOL(FileTypeGroup *g, NSUInteger i, BOOL *s) { return [g.key isEqual:@"html"]; }];
    FileTypeGroup *html = DefaultApps.groups[htmlIndex];
    NSUInteger before2 = calls;
    err = @"?";
    [a setGroup:html toFeather:YES done:^(NSString *e) { err = e; }];
    spinUntil(settled, 2);
    CHECK(html.unsupportedReason.length && [err containsString:@"browser"] && calls == before2, "HTML is not offered: %s", err.UTF8String);
    [p buildSheet];
    CHECK(!p.checkboxes[htmlIndex].enabled, "the HTML checkbox is disabled, with the reason next to it");

    // a refused change must not record a "previous app" (it would hand the type to the wrong app later)
    FileTypeGroup *pdf = nil;
    for (FileTypeGroup *g in DefaultApps.groups) if ([g.key isEqual:@"pdf"]) pdf = g;
    for (NSString *t in pdf.contentTypes) ls[t] = vscode;
    DefaultApps *refusing = make();
    refusing.setHandler = ^(NSURL *app, NSString *uti, void (^done)(NSError *)) {
        NSError *e = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError
                                     userInfo:@{NSUnderlyingErrorKey: [NSError errorWithDomain:NSOSStatusErrorDomain code:-54 userInfo:nil]}];
        dispatch_async(dispatch_get_main_queue(), ^{ done(e); });
    };
    err = @"?";
    [refusing setGroup:pdf toFeather:YES done:^(NSString *e) { err = e; }];
    spinUntil(settled, 2);
    CHECK([err containsString:@"Not permitted"] && ![store dictionaryForKey:@"previousDefaultApps"][pdf.contentTypes.firstObject],
          "a refused change is explained and remembers nothing: %s", err.UTF8String);
    [store removePersistentDomainForName:@"feather.tests.defaultapps"];
}

static void openFromFinder(NSString *dir) {
    NSString *ws = [dir stringByAppendingPathComponent:@"ws_finder"], *other = [dir stringByAppendingPathComponent:@"elsewhere"];
    for (NSString *x in @[ws, other]) [NSFileManager.defaultManager createDirectoryAtPath:x withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *inside = mkfile(ws, @"in.md", @"# in\n"), *a = mkfile(other, @"a.txt", @"a\n"), *b = mkfile(other, @"b.json", @"{}\n");
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [ud removeObjectForKey:@"NSWindow Frame FeatherMain"];
    [ud setObject:ws forKey:@"lastRoot"];
    [ud setObject:@{ws: @{@"tabs": @[@{@"path": inside, @"preview": @NO, @"line": @1}], @"active": @0}} forKey:@"sessions"];
    NSNotification *will = [NSNotification notificationWithName:NSApplicationWillFinishLaunchingNotification object:NSApp];
    NSNotification *did = [NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:NSApp];

    // cold launch by double-clicking two files: Finder delivers them before launch finishes
    AppDelegate *d = [AppDelegate new];
    [d applicationWillFinishLaunching:will];
    [d application:NSApp openURLs:@[[NSURL fileURLWithPath:a], [NSURL fileURLWithPath:b]]];
    CHECK(d->_content.tabCount == 0, "files are queued until launch finishes");
    [d applicationDidFinishLaunching:did];
    CHECK([d->_tree.rootPath isEqualToString:ws], "last workspace restored (%s)", d->_tree.rootPath.UTF8String);
    CHECK([d->_content.openPaths containsObject:inside] && [d->_content.openPaths containsObject:a] && [d->_content.openPaths containsObject:b],
          "session tabs + both double-clicked files: %s", [[d->_content.openPaths valueForKey:@"lastPathComponent"] componentsJoinedByString:@","].UTF8String);
    CHECK([d->_content.currentPath isEqualToString:b], "last opened file is in front");

    NSString *c = mkfile(other, @"c.py", @"x = 1\n");
    [d application:NSApp openURLs:@[[NSURL fileURLWithPath:c]]];
    CHECK([d->_tree.rootPath isEqualToString:ws] && [d->_content.currentPath isEqualToString:c], "while running: file from another folder opens as a tab, workspace unchanged");
    [d application:NSApp openURLs:@[[NSURL fileURLWithPath:other]]];
    CHECK([d->_tree.rootPath isEqualToString:other], "opening a folder switches the workspace");
    [d->_content closeAllWithoutAsking];

    for (NSString *k in @[@"lastRoot", @"sessions", @"recentRoots"]) [ud removeObjectForKey:k];
    AppDelegate *d2 = [AppDelegate new];
    [d2 applicationWillFinishLaunching:will];
    [d2 application:NSApp openURLs:@[[NSURL fileURLWithPath:a]]];
    [d2 applicationDidFinishLaunching:did];
    CHECK([d2->_tree.rootPath isEqualToString:other] && [d2->_content.currentPath isEqualToString:a], "first launch ever: opens the file's folder");
    [d2->_content closeAllWithoutAsking];
    for (NSString *k in @[@"lastRoot", @"sessions", @"recentRoots", @"NSWindow Frame FeatherMain"]) [ud removeObjectForKey:k];
}

static void htmlPreviewAndAutosave(NSString *dir) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"htmlLayout"];
    NSWindow *w; ContentController *t = offscreenController(&w);
    t.alertHandler = ^NSModalResponse(NSAlert *a) { return NSAlertThirdButtonReturn; };
    t.autoSaveMode = AutoSaveAfterDelay;
    t.autoSaveDelay = 0.2;
    NSString *hd = [dir stringByAppendingPathComponent:@"site"];
    [NSFileManager.defaultManager createDirectoryAtPath:hd withIntermediateDirectories:YES attributes:nil error:nil];
    NSBitmapImageRep *png = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:30 pixelsHigh:10 bitsPerSample:8
        samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [[png representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[hd stringByAppendingPathComponent:@"i.png"] atomically:YES];
    NSString *page = mkfile(hd, @"index.html",
        @"<html><body><h1 id=t>Hi</h1><img id=im src=\"i.png\"><script>document.title='js ran'</script></body></html>");
    t.workspaceRoot = dir;
    [t openPath:page preview:NO focus:NO];
    HTMLPreview *hv = findView(t.view, HTMLPreview.class);
    CHECK(hv && t.activeMarkupLayout == MarkupPreview, "html opens in preview");
    __block NSUInteger loads = 0;
    hv.onLoad = ^{ loads++; };
    CHECK(spinUntil(^BOOL { return loads > 0; }, 15), "web view finished loading");
    __block id title = nil, imgW = nil;
    [hv evaluate:@"document.title" done:^(id r) { title = r ?: @"?"; }];
    [hv evaluate:@"document.getElementById('im').naturalWidth" done:^(id r) { imgW = r ?: @0; }];
    spinUntil(^BOOL { return title && imgW; }, 5);
    CHECK([title isEqual:@"js ran"] && [imgW intValue] == 30, "page script ran (%s), relative image loaded (%d)", [title description].UTF8String, [imgW intValue]);

    t.activeMarkupLayout = MarkupSplit;
    CHECK(findView(t.view, HTMLPreview.class) == hv, "split keeps the same web view");
    [t.editor replaceAll:@"Hi" with:@"Hello"];
    CHECK(t.editor.isDirty, "edited");
    CHECK(spinUntil(^BOOL { return !t.editor.isDirty; }, 3), "auto-saved after a pause");
    CHECK([fileText(page, NSUTF8StringEncoding) containsString:@"Hello"], "auto-save wrote the file");
    __block id h1 = nil;
    CHECK(spinUntil(^BOOL { return loads > 1; }, 10), "preview reloaded after save");
    [hv evaluate:@"document.getElementById('t').textContent" done:^(id r) { h1 = r ?: @"?"; }];
    spinUntil(^BOOL { return h1 != nil; }, 5);
    CHECK([h1 isEqual:@"Hello"], "reloaded page shows the edit (%s)", [h1 description].UTF8String);
    [t closeAllWithoutAsking];

    // A page script can't open links or windows by itself; a click right before can.
    NSString *pushy = mkfile(hd, @"pushy.html",
        @"<html><body><a id=l href=\"https://example.com/clicked\">x</a><script>"
         "setTimeout(function(){document.getElementById('l').click(); window.open('https://example.com/popup');}, 10);"
         "</script></body></html>");
    HTMLPreview *pv = [[HTMLPreview alloc] initWithFrame:NSMakeRect(0, 0, 400, 300) path:pushy root:dir];
    __block NSMutableArray<NSURL *> *external = [NSMutableArray array];
    pv.onOpenExternal = ^(NSURL *u) { [external addObject:u]; };
    __block BOOL pl = NO;
    pv.onLoad = ^{ pl = YES; };
    spinUntil(^BOOL { return pl; }, 15);
    spinUntil(^BOOL { return external.count > 0; }, 1);
    CHECK(pl && external.count == 0, "script-driven link and window.open are ignored (%lu opened)", (unsigned long)external.count);
    [pv noteUserGesture];
    [pv evaluate:@"setTimeout(function(){document.getElementById('l').click()}, 0); 1" done:nil];
    spinUntil(^BOOL { return external.count > 0; }, 5);
    CHECK(external.count == 1 && [external[0].absoluteString isEqualToString:@"https://example.com/clicked"],
          "a link right after a click opens once (%s)", external.description.UTF8String);
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"htmlLayout"];
}

static void autosave(NSString *dir) {
    NSWindow *w; ContentController *t = offscreenController(&w);
    __block NSUInteger asked = 0;
    t.alertHandler = ^NSModalResponse(NSAlert *a) { asked++; return NSAlertSecondButtonReturn; };
    t.autoSaveMode = AutoSaveAfterDelay;
    t.autoSaveDelay = 0.15;
    NSString *ad = [dir stringByAppendingPathComponent:@"as"];
    [NSFileManager.defaultManager createDirectoryAtPath:ad withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *a = mkfile(ad, @"a.txt", @"a\n"), *b = mkfile(ad, @"b.txt", @"b\n"), *c = mkfile(ad, @"c.txt", @"c\n");

    [t openPath:a preview:NO focus:NO];
    [t.editor insertText:@"1" replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK(spinUntil(^BOOL { return !t.editor.isDirty; }, 3) && [fileText(a, NSUTF8StringEncoding) isEqualToString:@"1a\n"], "saved after a pause");
    CHECK(asked == 0, "no prompt");

    mkfile(ad, @"a.txt", @"changed elsewhere\n");
    [t.editor insertText:@"2" replacementRange:NSMakeRange(NSNotFound, 0)];
    spinUntil(^BOOL { return [t.statusText containsString:@"Changed on disk"]; }, 3);
    CHECK([t.statusText containsString:@"changed on disk"] && t.editor.isDirty, "never overwrites an externally changed file: %s", t.statusText.UTF8String);
    CHECK([fileText(a, NSUTF8StringEncoding) isEqualToString:@"changed elsewhere\n"] && asked == 0, "disk content kept, still no prompt");

    t.autoSaveMode = AutoSaveOnFocusChange;
    [t openPath:b preview:NO focus:NO];                           // leaving a: tried again, still refused
    [t.editor insertText:@"3" replacementRange:NSMakeRange(NSNotFound, 0)];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
    CHECK(t.editor.isDirty, "focus-change mode does not save while typing");
    chmod(b.fileSystemRepresentation, 0444);
    [t openPath:c preview:NO focus:NO];
    [t selectTabAtIndex:1];
    CHECK([t.statusText containsString:@"Auto-save failed"] && t.editor.isDirty && asked == 0, "failed auto-save is reported in the status bar: %s", t.statusText.UTF8String);
    chmod(b.fileSystemRepresentation, 0644);
    chmod(ad.fileSystemRepresentation, 0555);                   // a read-only folder: the writable file is saved in place
    [t openPath:c preview:NO focus:NO];
    chmod(ad.fileSystemRepresentation, 0755);
    CHECK([fileText(b, NSUTF8StringEncoding) isEqualToString:@"3b\n"], "switching tabs saves the one you leave, even in a read-only folder");
    [t.editor insertText:@"4" replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK([t closeActive] && asked == 0 && [fileText(c, NSUTF8StringEncoding) isEqualToString:@"4c\n"], "closing a tab saves silently");
    CHECK([t flushAutoSave] == NO, "flush reports the file it could not save (a.txt)");
    [t closeAllWithoutAsking];
}

static void layoutAndWorkspaces(NSString *dir) {
    // Start from the default 1100-wide window; the blank-strip bug only shows when the window is wider than the panes' initial sum.
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"NSWindow Frame FeatherMain"];
    AppDelegate *d = [AppDelegate new];
    [d applicationWillFinishLaunching:[NSNotification notificationWithName:NSApplicationWillFinishLaunchingNotification object:NSApp]];
    void (^checkFill)(NSString *) = ^(NSString *when) {
        NSView *pane = d->_content.view;
        CGFloat right = NSMaxX(pane.frame), w = d->_split.bounds.size.width;
        CHECK(fabs(right - w) < 1, "%s: right pane reaches the window edge (%.0f of %.0f)", when.UTF8String, right, w);
        CHECK(!d->_welcome.hidden && NSEqualRects(d->_welcome.frame, pane.bounds), "%s: welcome page fills the pane", when.UTF8String);
    };
    checkFill(@"initial");
    [d->_win setFrame:NSMakeRect(0, 0, 1500, 900) display:NO];
    checkFill(@"1500x900");
    [d->_win setFrame:NSMakeRect(0, 0, 700, 500) display:NO];
    checkFill(@"700x500");

    NSString *r1 = [dir stringByAppendingPathComponent:@"ws1"], *r2 = [dir stringByAppendingPathComponent:@"ws2"];
    [NSFileManager.defaultManager createDirectoryAtPath:r1 withIntermediateDirectories:YES attributes:nil error:nil];
    [NSFileManager.defaultManager createDirectoryAtPath:r2 withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *f1 = mkfile(r1, @"a.txt", @"a\n");
    [d openRoot:r1];
    CHECK([d->_rootPopup.menu.itemArray.firstObject.title isEqualToString:@"ws1"], "header shows workspace name");
    [d openFile:f1];
    CHECK(d->_content.tabCount == 1 && d->_welcome.hidden, "tab replaces welcome page");
    CHECK([d switchToRoot:r2] && d->_content.tabCount == 0 && [d->_tree.rootPath isEqualToString:r2], "switch workspace");
    [d rebuildRootPopupMenu:d->_rootPopup.menu];
    NSMenuItem *ws1 = nil, *ws2 = nil;
    NSMenuItem *remove1 = nil;
    for (NSMenuItem *i in d->_rootPopup.menu.itemArray) {
        if (i.isAlternate) { if ([i.representedObject isEqual:r1]) remove1 = i; continue; }
        if ([i.representedObject isEqual:r1]) ws1 = i;
        if ([i.representedObject isEqual:r2]) ws2 = i;
    }
    CHECK(remove1 && remove1.keyEquivalentModifierMask == NSEventModifierFlagOption && [remove1.title containsString:@"Remove"],
          "holding ⌥ turns another workspace's item into 从列表中移除");
    CHECK(ws1 && ws2 && ws2.state == NSControlStateValueOn && ws1.state == NSControlStateValueOff, "dropdown lists workspaces, current checked");
    [NSApp sendAction:ws1.action to:d from:ws1];
    CHECK([d->_tree.rootPath isEqualToString:r1] && [d->_content.currentPath isEqualToString:f1],
          "clicking a workspace switches back and restores its tabs");
    for (NSString *k in @[@"lastRoot", @"recentRoots", @"sessions", @"NSWindow Frame FeatherMain"])
        [NSUserDefaults.standardUserDefaults removeObjectForKey:k];
}

#pragma mark Rendered data files

static void dataViews(NSString *dir) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    for (NSString *k in @[@"tableLayout", @"jsonLayout", @"plistLayout", @"notebookLayout"]) [ud removeObjectForKey:k];
    NSWindow *w; ContentController *t = offscreenController(&w);
    t.alertHandler = ^NSModalResponse(NSAlert *a) { return NSAlertThirdButtonReturn; };

    NSString *csv = mkfile(dir, @"people.csv", @"name,age,city\nZoe,31,Paris\nadam,9,\"New York, NY\"\nBea,100,Oslo\n");
    [t openPath:csv preview:NO focus:NO];
    TablePreview *tp = findView(t.view, TablePreview.class);
    CHECK(t.activeMarkupKind == MarkupTable && t.activeMarkupLayout == MarkupPreview && tp, "a CSV opens as a table");
    CHECK(tp.visibleRowCount == 3 && tp.tableView.numberOfColumns == 4 && [tp.tableView.tableColumns[1].title isEqual:@"name"] &&
          [[tp displayedCellAtRow:1 column:2] isEqual:@"New York, NY"], "header row, quoted comma (%lu rows, %ld cols)",
          (unsigned long)tp.visibleRowCount, (long)tp.tableView.numberOfColumns);
    [tp sortByColumn:1 ascending:YES];
    CHECK([[tp displayedCellAtRow:0 column:1] isEqual:@"9"] && [[tp displayedCellAtRow:2 column:1] isEqual:@"100"], "numbers sort as numbers, not text");
    [tp sortByColumn:0 ascending:YES];
    CHECK([[tp displayedCellAtRow:0 column:0] isEqual:@"adam"], "text sorts ignoring case");
    tp.filterText = @"city:o";
    CHECK(tp.visibleRowCount == 2 && [tp.infoText containsString:@"2 of 3 rows"], "filter on one column: %s", tp.infoText.UTF8String);
    tp.filterText = @"";
    [tp sortByColumn:-1 ascending:YES];
    [t.editor gotoLine:5];
    [t.editor insertText:@"Cy,7,Rome\n" replacementRange:NSMakeRange(NSNotFound, 0)];
    spinUntil(^BOOL { return tp.model.rowCount == 4; }, 3);
    CHECK(tp.model.rowCount == 4, "editing the source updates the table (%lu rows)", (unsigned long)tp.model.rowCount);
    CHECK([tp.model sourceLineOfRow:2] == 4, "row 3 comes from line 4");
    tp.onJumpToLine(4);
    CHECK(t.activeMarkupLayout == MarkupSplit && t.editor.caretLine == 4, "double-clicking a row shows the source beside it at that line (%lu)",
          (unsigned long)t.editor.caretLine);

    NSString *tsv = mkfile(dir, @"x.tsv", @"a\tb\n1\t2\n");
    [t openPath:tsv preview:NO focus:NO];
    t.activeMarkupLayout = MarkupPreview;
    tp = findView(t.view, TablePreview.class);
    CHECK(tp.tableView.numberOfColumns == 3 && [[tp displayedCellAtRow:0 column:1] isEqual:@"2"], "TSV");

    // A very wide CSV shows its first columns instead of building one table column per field.
    NSMutableString *wide = [NSMutableString string];
    for (int r = 0; r < 2; r++) { for (int c = 0; c < 200000; c++) [wide appendString:c ? @",1" : @"1"]; [wide appendString:@"\n"]; }
    NSString *wp = [dir stringByAppendingPathComponent:@"wide.csv"];
    [wide writeToFile:wp atomically:YES encoding:NSUTF8StringEncoding error:nil];
    CFAbsoluteTime w0 = CFAbsoluteTimeGetCurrent();
    [t openPath:wp preview:NO focus:NO];
    t.activeMarkupLayout = MarkupPreview;
    tp = findView(t.view, TablePreview.class);
    spinUntil(^BOOL { return tp.model.columnCount == 200000; }, 10);
    CHECK(tp.model.columnCount == 200000 && tp.tableView.numberOfColumns <= 1001 && [tp.infoText containsString:@"first 1,000 shown"] &&
          CFAbsoluteTimeGetCurrent() - w0 < 5, "200 000 columns: %ld shown in %.1f s (%s)", (long)tp.tableView.numberOfColumns,
          CFAbsoluteTimeGetCurrent() - w0, tp.infoText.UTF8String);

    NSString *json = mkfile(dir, @"package.json", @"{\n  \"name\": \"demo\",\n  // comment\n  \"deps\": {\"b\": \"^1\", \"a\": \"^2\"},\n  \"n\": [1, 2, 3]\n}\n");
    [t openPath:json preview:NO focus:NO];
    CHECK(t.activeMarkupKind == MarkupJSON && t.activeMarkupLayout == MarkupSource, "JSON opens as source by default");
    t.activeMarkupLayout = MarkupPreview;
    TreePreview *tree = findView(t.view, TreePreview.class);
    CHECK(tree.root.children.count == 3 && [tree.root.children[1].children[0].key isEqual:@"b"] && tree.outlineView.numberOfRows >= 3,
          "tree keeps the file's key order (%ld rows)", (long)tree.outlineView.numberOfRows);
    tree.filterText = @"^2";
    CHECK(tree.outlineView.numberOfRows == 2 && [tree.outlineView itemAtRow:1] == tree.root.children[1].children[1], "filter keeps the match and its parent (%ld rows)",
          (long)tree.outlineView.numberOfRows);
    tree.filterText = @"";
    [t.editor gotoLine:2];
    [t.editor insertText:@"oops " replacementRange:NSMakeRange(NSNotFound, 0)];
    spinUntil(^BOOL { return tree.errorText != nil; }, 3);
    CHECK([tree.errorText containsString:@"Line 2,"] && tree.root.children.count == 3, "a typo shows where, and keeps the last good tree: %s", tree.errorText.UTF8String);
    [t.editor undo:nil];
    spinUntil(^BOOL { return tree.errorText == nil; }, 3);
    CHECK(!tree.errorText, "fixing it clears the error");

    NSDictionary *nb = @{@"metadata": @{}, @"cells": @[@{@"cell_type": @"markdown", @"source": @"# Notebook title"},
        @{@"cell_type": @"code", @"execution_count": @1, @"source": @"1+1", @"outputs": @[@{@"output_type": @"execute_result", @"data": @{@"text/plain": @"2"}}]}]};
    NSString *ipynb = [dir stringByAppendingPathComponent:@"a.ipynb"];
    [[NSJSONSerialization dataWithJSONObject:nb options:0 error:nil] writeToFile:ipynb atomically:YES];
    [t openPath:ipynb preview:NO focus:NO];
    MarkdownPreview *mp = findView(t.view, MarkdownPreview.class);
    CHECK(t.activeMarkupKind == MarkupNotebook && [mp.textView.string containsString:@"Notebook title"] && [mp.textView.string containsString:@"1+1"],
          "notebook rendered: %s", [mp.textView.string substringToIndex:MIN((NSUInteger)60, mp.textView.string.length)].UTF8String);

    NSString *plist = [dir stringByAppendingPathComponent:@"Info.plist"];
    [@{@"CFBundleName": @"X", @"Arr": @[@1]} writeToFile:plist atomically:YES];
    [t openPath:plist preview:NO focus:NO];
    CHECK(t.activeMarkupKind == MarkupPlist && t.editor, "an XML plist opens as text with a tree view");
    [t closeAllWithoutAsking];
    for (NSString *k in @[@"tableLayout", @"jsonLayout", @"plistLayout", @"notebookLayout"]) [ud removeObjectForKey:k];
}

static void binaryViews(NSString *dir) {
    NSWindow *w; ContentController *t = offscreenController(&w);
    NSString *bplist = [dir stringByAppendingPathComponent:@"bin.plist"];
    NSData *bin = [NSPropertyListSerialization dataWithPropertyList:@{@"key": @"value", @"list": @[@1, @2]} format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    [bin writeToFile:bplist atomically:YES];
    [t openPath:bplist preview:NO focus:NO];
    TreePreview *tree = findView(t.view, TreePreview.class);
    CHECK(tree && !t.editor && tree.root.children.count == 2 && [t.statusText containsString:@"Binary property list"], "a binary plist shows as a tree (was hex)");

    NSString *dbp = [dir stringByAppendingPathComponent:@"app.db"];
    sqlite3 *db = NULL;
    sqlite3_open(dbp.fileSystemRepresentation, &db);
    sqlite3_exec(db, "CREATE TABLE users(id INTEGER, name TEXT, avatar BLOB); INSERT INTO users VALUES (1,'ann',x'0102'),(2,NULL,NULL);"
                     "CREATE VIEW v AS SELECT name FROM users;", NULL, NULL, NULL);
    sqlite3_close(db);
    [t openPath:dbp preview:NO focus:NO];
    SQLitePreview *sp = findView(t.view, SQLitePreview.class);
    CHECK(sp && [sp.tableNames isEqualToArray:(@[@"users", @"v"])], "SQLite: tables and views (%s)", [sp.tableNames componentsJoinedByString:@","].UTF8String);
    spinUntil(^BOOL { return sp.grid.model.rowCount == 2; }, 3);
    CHECK(sp.grid.model.rowCount == 2 && [[sp.grid.model cellAtRow:0 column:2] isEqual:@"<BLOB 2 bytes>"] && [[sp.grid.model cellAtRow:1 column:1] isEqual:@"NULL"],
          "rows, BLOB and NULL shown readably");
    [sp runQuery:@"DELETE FROM users"];
    spinUntil(^BOOL { return [sp.grid.infoText containsString:@"⚠️"]; }, 3);
    db = NULL;
    sqlite3_open(dbp.fileSystemRepresentation, &db);
    sqlite3_stmt *st = NULL; int count = -1;
    if (sqlite3_prepare_v2(db, "SELECT count(*) FROM users", -1, &st, NULL) == SQLITE_OK && sqlite3_step(st) == SQLITE_ROW) count = sqlite3_column_int(st, 0);
    sqlite3_finalize(st); sqlite3_close(db);
    CHECK(count == 2 && [sp.grid.infoText containsString:@"⚠️"], "the database is read-only: a DELETE fails and changes nothing (%d rows): %s", count, sp.grid.infoText.UTF8String);
    [sp runQuery:@"SELECT name FROM users WHERE id = 1"];
    spinUntil(^BOOL { return sp.grid.model.rowCount == 1 && sp.grid.model.columnCount == 1; }, 3);
    CHECK([[sp.grid.model cellAtRow:0 column:0] isEqual:@"ann"], "a SELECT runs");
    NSString *vac = [dir stringByAppendingPathComponent:@"vacuum-copy.db"];
    [sp runQuery:[NSString stringWithFormat:@"VACUUM INTO '%@'", vac]];
    spinUntil(^BOOL { return [sp.grid.infoText containsString:@"⚠️"]; }, 3);
    CHECK(![NSFileManager.defaultManager fileExistsAtPath:vac] && [sp.grid.infoText containsString:@"⚠️"], "VACUUM INTO writes no file: %s", sp.grid.infoText.UTF8String);
    [sp runQuery:@"WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n) SELECT count(*) FROM n"];   // never ends
    CFAbsoluteTime q0 = CFAbsoluteTimeGetCurrent();
    [sp runQuery:@"SELECT 42 AS answer"];
    spinUntil(^BOOL { return [[sp.grid.model headerForColumn:0] isEqual:@"answer"]; }, 5);
    CHECK([[sp.grid.model cellAtRow:0 column:0] isEqual:@"42"] && CFAbsoluteTimeGetCurrent() - q0 < 3, "a new query stops a runaway one (%.1f s)", CFAbsoluteTimeGetCurrent() - q0);

    // A WAL database in a read-only folder: read from a copy, including changes not yet checkpointed.
    NSString *wd = [dir stringByAppendingPathComponent:@"walsrc"], *rod = [dir stringByAppendingPathComponent:@"walro"];
    [NSFileManager.defaultManager createDirectoryAtPath:wd withIntermediateDirectories:YES attributes:nil error:nil];
    [NSFileManager.defaultManager createDirectoryAtPath:rod withIntermediateDirectories:YES attributes:nil error:nil];
    sqlite3 *wdb = NULL;
    sqlite3_open([wd stringByAppendingPathComponent:@"w.db"].fileSystemRepresentation, &wdb);
    sqlite3_exec(wdb, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE notes(t); INSERT INTO notes VALUES('in the wal');", NULL, NULL, NULL);
    for (NSString *f in @[@"w.db", @"w.db-wal"])
        [NSFileManager.defaultManager copyItemAtPath:[wd stringByAppendingPathComponent:f] toPath:[rod stringByAppendingPathComponent:f] error:nil];
    sqlite3_close(wdb);
    chmod(rod.fileSystemRepresentation, 0555);
    SQLitePreview *wp = [[SQLitePreview alloc] initWithFrame:NSMakeRect(0, 0, 600, 400) path:[rod stringByAppendingPathComponent:@"w.db"]];
    spinUntil(^BOOL { return wp.grid.model.rowCount == 1; }, 3);
    CHECK(wp && [wp.tableNames isEqualToArray:@[@"notes"]] && [[wp.grid.model cellAtRow:0 column:0] isEqual:@"in the wal"] && [wp.status containsString:@"copy"],
          "WAL database in a read-only folder shows its tables and recent rows: %s", wp.status.UTF8String);
    wp = nil;
    chmod(rod.fileSystemRepresentation, 0755);

    NSString *src = [dir stringByAppendingPathComponent:@"zipsrc"];
    [NSFileManager.defaultManager createDirectoryAtPath:[src stringByAppendingPathComponent:@"docs"] withIntermediateDirectories:YES attributes:nil error:nil];
    mkfile(src, @"readme.txt", @"hello from the zip\n");
    mkfile([src stringByAppendingPathComponent:@"docs"], @"a b.md", @"# spaced name\n");
    NSString *zip = [dir stringByAppendingPathComponent:@"pack.zip"];
    NSTask *z = [NSTask new];
    z.executableURL = [NSURL fileURLWithPath:@"/usr/bin/zip"];
    z.arguments = @[@"-qr", zip, @"."];
    z.currentDirectoryURL = [NSURL fileURLWithPath:src];
    [z launchAndReturnError:nil];
    [z waitUntilExit];
    [t openPath:zip preview:NO focus:NO];
    ArchivePreview *ap = findView(t.view, ArchivePreview.class);
    spinUntil(^BOOL { return ap.loaded; }, 5);
    NSMutableSet *names = [NSMutableSet set];
    NSUInteger row = NSNotFound;
    for (NSUInteger r = 0; r < ap.grid.model.rowCount; r++) {
        NSString *n = [ap.grid.model cellAtRow:r column:0];
        [names addObject:n];
        if ([n isEqual:@"docs/a b.md"]) row = r;
    }
    CHECK(ap && [names containsObject:@"readme.txt"] && row != NSNotFound, "zip listed (was hex): %s", names.description.UTF8String);
    CHECK(row != NSNotFound && [[ap.grid.model cellAtRow:row column:1] isEqual:@"14"], "size column, name with a space");
    __block NSString *opened = nil;
    ap.onOpenFile = ^(NSString *p) { opened = p; };
    if (row != NSNotFound) ap.grid.onActivateRow(row);
    spinUntil(^BOOL { return opened != nil; }, 5);
    CHECK([fileText(opened, NSUTF8StringEncoding) isEqualToString:@"# spaced name\n"], "double-click extracts and opens the entry");
    [t closeAllWithoutAsking];

    // An archive entry that is a link to a file outside the archive is not opened (saving would write through it).
    NSString *tsrc = [dir stringByAppendingPathComponent:@"tarsrc"];
    [NSFileManager.defaultManager createDirectoryAtPath:tsrc withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *victim = mkfile(dir, @"victim.txt", @"do not touch\n");
    symlink(victim.fileSystemRepresentation, [tsrc stringByAppendingPathComponent:@"readme.md"].fileSystemRepresentation);
    mkfile(tsrc, @"a*.txt", @"star\n");
    mkfile(tsrc, @"ab.txt", @"plain\n");
    mkfile(tsrc, @"中文.txt", @"汉字\n");
    NSString *tar = [dir stringByAppendingPathComponent:@"pack.tar"];
    NSTask *tt = [NSTask new];
    tt.executableURL = [NSURL fileURLWithPath:@"/usr/bin/tar"];
    tt.arguments = @[@"-cf", tar, @"readme.md", @"a*.txt", @"ab.txt", @"中文.txt"];
    tt.currentDirectoryURL = [NSURL fileURLWithPath:tsrc];
    [tt launchAndReturnError:nil];
    [tt waitUntilExit];
    ArchivePreview *tp = [[ArchivePreview alloc] initWithFrame:NSMakeRect(0, 0, 600, 400) path:tar];
    spinUntil(^BOOL { return tp.loaded; }, 5);
    NSMutableDictionary<NSString *, NSNumber *> *rowOf = [NSMutableDictionary dictionary];
    for (NSUInteger r = 0; r < tp.grid.model.rowCount; r++) rowOf[[tp.grid.model cellAtRow:r column:0]] = @(r);
    CHECK(rowOf[@"中文.txt"] && rowOf[@"a*.txt"], "names are listed as UTF-8: %s", rowOf.allKeys.description.UTF8String);
    __block NSString *got = nil, *msg = nil;
    tp.onOpenFile = ^(NSString *p) { got = p; };
    tp.onMessage = ^(NSString *m) { msg = m; };
    if (rowOf[@"readme.md"]) tp.grid.onActivateRow(rowOf[@"readme.md"].unsignedIntegerValue);
    spinUntil(^BOOL { return got || msg; }, 5);
    CHECK(!got && msg.length, "a link entry is refused: %s", msg.UTF8String);
    got = nil;
    if (rowOf[@"a*.txt"]) tp.grid.onActivateRow(rowOf[@"a*.txt"].unsignedIntegerValue);
    spinUntil(^BOOL { return got != nil; }, 5);
    CHECK([fileText(got, NSUTF8StringEncoding) isEqualToString:@"star\n"] &&
          ![NSFileManager.defaultManager fileExistsAtPath:[got.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"ab.txt"]],
          "a name with * extracts only that entry");
    got = nil;
    if (rowOf[@"中文.txt"]) tp.grid.onActivateRow(rowOf[@"中文.txt"].unsignedIntegerValue);
    spinUntil(^BOOL { return got != nil; }, 5);
    CHECK([fileText(got, NSUTF8StringEncoding) isEqualToString:@"汉字\n"], "a CJK name extracts");
    CHECK([fileText(victim, NSUTF8StringEncoding) isEqualToString:@"do not touch\n"], "the linked file is untouched");
}

static void hiddenFileSettings(NSString *dir) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSString *root = [dir stringByAppendingPathComponent:@"ws_hidden"];
    for (NSString *rel in @[@".env", @".git/HEAD", @".DS_Store", @"cache.pyc", @"main.py"]) {
        NSString *p = [root stringByAppendingPathComponent:rel];
        [NSFileManager.defaultManager createDirectoryAtPath:p.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        [@"x" writeToFile:p atomically:NO encoding:NSUTF8StringEncoding error:nil];
    }
    FileOutlineView *ov = [[FileOutlineView alloc] initWithFrame:NSMakeRect(0, 0, 200, 400)];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"n"];
    [ov addTableColumn:col];
    ov.outlineTableColumn = col;
    FileTree *tree = [[FileTree alloc] initWithOutlineView:ov];
    FTSettings *st = FTSettings.shared;
    [st resetFileLists];
    tree.showHidden = st.showHidden;
    tree.rootPath = root;
    NSSet *(^names)(void) = ^NSSet * {
        NSMutableSet *s = [NSMutableSet set];
        for (NSInteger r = 0; r < ov.numberOfRows; r++) [s addObject:[(FileNode *)[ov itemAtRow:r] name]];
        return s;
    };
    CHECK(st.showHidden && [names() containsObject:@".env"] && ![names() containsObject:@".git"] && ![names() containsObject:@".DS_Store"],
          "default: dot files are shown, .git and .DS_Store are not: %s", names().description.UTF8String);
    st.showHidden = NO;
    tree.showHidden = st.showHidden;
    CHECK(![names() containsObject:@".env"] && [names() containsObject:@"main.py"] && ![ud boolForKey:@"showHidden"], "turned off, and remembered");
    st.showHidden = YES;
    tree.showHidden = YES;

    SettingsWindow *sw = SettingsWindow.shared;
    [sw reloadFromSettings];
    sw.alwaysHiddenField.stringValue = @".git, .DS_Store, *.pyc";
    [sw commitFields];
    [tree reload];
    CHECK(![names() containsObject:@"cache.pyc"] && [names() containsObject:@"main.py"] && [st.alwaysHidden containsObject:@"*.pyc"],
          "a glob added in 设置 hides *.pyc: %s", names().description.UTF8String);
    sw.alwaysHiddenField.stringValue = @"";
    [sw commitFields];
    [tree reload];
    CHECK([names() containsObject:@".git"] && [names() containsObject:@".DS_Store"], "an empty list shows everything");
    sw.alwaysHiddenField.stringValue = @".git, *.log";                // typed, Return not pressed
    [sw windowWillClose:[NSNotification notificationWithName:NSWindowWillCloseNotification object:sw.window]];
    CHECK([st.alwaysHidden isEqualToArray:(@[@".git", @"*.log"])], "closing Settings keeps a list typed without Return: %s", st.alwaysHidden.description.UTF8String);
    CHECK(st.remoteImages && MarkdownRenderer.loadsRemoteImages, "web images load by default");
    [sw.remoteImagesBox performClick:nil];
    CHECK(!st.remoteImages && !MarkdownRenderer.loadsRemoteImages, "the Previews checkbox turns web images off");
    [sw.remoteImagesBox performClick:nil];
    [ud removeObjectForKey:@"remoteImages"];
    [sw.showHiddenBox performClick:nil];
    CHECK(!st.showHidden, "the checkbox in 设置 changes the setting");
    [st resetFileLists];
    [sw reloadFromSettings];
    CHECK(st.showHidden && [sw.alwaysHiddenField.stringValue containsString:@".git"], "恢复默认");
    for (NSString *k in @[@"showHidden", @"alwaysHidden", @"searchSkipped", @"respectGitignore"]) [ud removeObjectForKey:k];
    [st apply];
}

#pragma mark Untitled documents, recent workspaces, appearance

static void untitledDocuments(NSString *dir) {
    NSString *backups = [dir stringByAppendingPathComponent:@"untitled-backups"];
    NSString *ws = [dir stringByAppendingPathComponent:@"ws_untitled"];
    [NSFileManager.defaultManager createDirectoryAtPath:ws withIntermediateDirectories:YES attributes:nil error:nil];
    NSWindow *w; ContentController *t = offscreenController(&w);
    t.untitledDirectory = backups;
    t.workspaceRoot = ws;
    t.autoSaveMode = AutoSaveOff;                                    // backups must happen anyway
    __block NSInteger answer = NSAlertSecondButtonReturn;
    __block NSUInteger asked = 0;
    t.alertHandler = ^NSModalResponse(NSAlert *a) { asked++; return answer; };
    __block NSString *suggested = nil, *saveTo = nil;
    t.savePathHandler = ^NSString *(NSString *name, NSString *d) { suggested = name; return saveTo; };
    NSUInteger (^backupCount)(void) = ^NSUInteger { return [NSFileManager.defaultManager contentsOfDirectoryAtPath:backups error:nil].count; };

    [t newUntitledDocument];
    CHECK(t.tabCount == 1 && t.activeIsUntitled && [t.currentTitle isEqual:@"Untitled-1"] && !t.currentPath && t.editor,
          "⌘N opens an editable 未命名-1 tab with no file behind it");
    CHECK(t.dirtyCount == 0, "an empty untitled tab is not unsaved");
    [t.editor insertText:@"# Shopping list\nmilk\n" replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK(t.dirtyCount == 1, "with text it counts as unsaved");
    [t newUntitledDocument];
    CHECK([t.currentTitle isEqual:@"Untitled-2"], "the next one is Untitled-2");
    [t.editor insertText:@"second" replacementRange:NSMakeRange(NSNotFound, 0)];
    [t backupUntitled];
    NSMutableSet *texts = [NSMutableSet set];
    for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:backups error:nil])
        [texts addObject:fileText([backups stringByAppendingPathComponent:f], NSUTF8StringEncoding)];
    CHECK(backupCount() == 2 && [texts containsObject:@"second"] && [texts containsObject:@"# Shopping list\nmilk\n"],
          "the text is backed up even with auto-save off (%lu files)", (unsigned long)backupCount());

    asked = 0;
    CHECK([t confirmCloseAll] && asked == 0, "switching away does not ask about untitled tabs");
    NSDictionary *session = t.sessionState;
    CHECK([ContentController untitledBackupsInSessions:@{ws: session}].count == 2, "the session lists both backups");
    [t closeAllWithoutAsking];
    CHECK(backupCount() == 2, "closing the workspace keeps the backups");
    [t restoreSession:session];
    CHECK(t.tabCount == 2 && t.activeIsUntitled && [t.currentTitle isEqual:@"Untitled-2"] && [text(t.editor) isEqualToString:@"second"],
          "restored with titles and text: %s", t.currentTitle.UTF8String);

    answer = NSAlertSecondButtonReturn;
    asked = 0;
    CHECK(![t closeActive] && asked == 1 && t.tabCount == 2, "closing asks, 取消 keeps the tab");
    answer = NSAlertThirdButtonReturn;
    CHECK([t closeActive] && t.tabCount == 1 && backupCount() == 1, "不保存 closes it and drops its backup");

    [t selectTabAtIndex:0];
    saveTo = [ws stringByAppendingPathComponent:@"shopping.md"];
    CHECK([t save] && [suggested isEqualToString:@"Shopping list.txt"], "⌘S asks where to save, suggesting “%s”", suggested.UTF8String);
    CHECK(!t.activeIsUntitled && [t.currentPath isEqual:saveTo] && [fileText(saveTo, NSUTF8StringEncoding) isEqualToString:@"# Shopping list\nmilk\n"] &&
          t.activeIsMarkup && t.dirtyCount == 0, "saved as shopping.md: now a normal Markdown tab");
    struct stat st;
    CHECK(stat(saveTo.fileSystemRepresentation, &st) == 0 && (st.st_mode & 0777) == 0644, "the new file is 0644 (%o)", st.st_mode & 0777);
    CHECK(backupCount() == 0, "no backups left");

    [t newUntitledDocument];
    [t.editor insertText:@"draft" replacementRange:NSMakeRange(NSNotFound, 0)];
    saveTo = nil;
    CHECK(![t save] && t.activeIsUntitled && [t.currentTitle isEqual:@"Untitled-1"], "cancelling the save panel keeps it untitled (number reused)");
    answer = NSAlertFirstButtonReturn;
    CHECK(![t closeActive] && t.tabCount == 2, "保存… then cancelling the panel keeps it open");

    [t newUntitledDocument];
    asked = 0;
    CHECK([t closeActive] && asked == 0, "an empty untitled tab closes silently");
    answer = NSAlertThirdButtonReturn;
    asked = 0;
    CHECK([t closeAll] && asked == 1 && t.tabCount == 0 && backupCount() == 0, "全部关闭 → 不保存 drops them");
    for (int k = 0; k < 6; k++) [t openPath:mkfile(ws, [NSString stringWithFormat:@"tab%d.txt", k], @"x\n") preview:NO focus:NO];
    [t selectTabAtIndex:0];
    NSUInteger loads = t.viewerLoads;
    CHECK([t closeAll] && t.tabCount == 0 && t.viewerLoads == loads, "Close All doesn't load each next tab (%lu loads)", (unsigned long)(t.viewerLoads - loads));
    [NSFileManager.defaultManager removeItemAtPath:backups error:nil];
}

static void recentAndAppearance(NSString *dir) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    for (NSString *k in @[@"lastRoot", @"recentRoots", @"sessions", @"appearance", @"NSWindow Frame FeatherMain"]) [ud removeObjectForKey:k];
    NSString *a = [dir stringByAppendingPathComponent:@"ws_ra"], *b = [dir stringByAppendingPathComponent:@"ws_rb"], *c = [dir stringByAppendingPathComponent:@"ws_rc"];
    for (NSString *x in @[a, b, c]) [NSFileManager.defaultManager createDirectoryAtPath:x withIntermediateDirectories:YES attributes:nil error:nil];
    AppDelegate *d = [AppDelegate new];
    [d applicationWillFinishLaunching:[NSNotification notificationWithName:NSApplicationWillFinishLaunchingNotification object:NSApp]];
    d->_content.untitledDirectory = [dir stringByAppendingPathComponent:@"untitled-ra"];
    d->_content.alertHandler = ^NSModalResponse(NSAlert *al) { return NSAlertThirdButtonReturn; };
    [d openRoot:a];
    [d->_content newUntitledDocument];
    NSMenuItem *saveItem = [[NSMenuItem alloc] initWithTitle:@"Save" action:@selector(saveDocument:) keyEquivalent:@"s"];
    CHECK([d validateMenuItem:saveItem], "⌘S is enabled on a new, empty document");
    [d->_content.editor insertText:@"keep me" replacementRange:NSMakeRange(NSNotFound, 0)];
    [d->_content backupUntitled];                              // what auto-save does a second after typing stops
    CHECK(!d->_content.editor.isDirty && [d validateMenuItem:saveItem], "⌘S stays enabled after the draft was backed up");
    __block NSUInteger asked = 0;
    d->_content.savePathHandler = ^NSString *(NSString *name, NSString *folder) { asked++; return nil; };
    [NSApp sendAction:@selector(saveDocument:) to:d from:saveItem];
    CHECK(asked == 1 && d->_content.activeIsUntitled, "⌘S on a backed-up draft asks where to save it");
    d->_content.savePathHandler = nil;
    [d updateTitle];
    CHECK([d->_win.title isEqualToString:@"Untitled-1"] && !d->_win.representedURL && d->_win.isDocumentEdited, "window title: %s", d->_win.title.UTF8String);
    CHECK([d targetPathsFrom:nil].count == 0, "file actions (trash, rename, reveal) have no target on an untitled tab");
    CHECK([d switchToRoot:b], "switching workspace with an untitled tab doesn't ask");
    [d openRoot:c];
    NSArray *three = @[c, b, a];
    CHECK([d.recentRoots isEqualToArray:three], "three recent workspaces");

    [d removeRecentRoot:b];
    NSArray *two = @[c, a];
    CHECK([d.recentRoots isEqualToArray:two], "one entry removed, the others stay: %s", [d.recentRoots componentsJoinedByString:@","].UTF8String);
    d->_welcome.onRemoveRecent(a);
    [d saveSession];
    CHECK([d.recentRoots isEqualToArray:@[c]], "the welcome page's × removes one too");
    CHECK([ud dictionaryForKey:@"sessions"][a] != nil, "a removed workspace keeps its untitled documents");
    [d openRoot:a];
    CHECK(d->_content.tabCount == 1 && [d->_content.currentTitle isEqual:@"Untitled-1"] && [text(d->_content.editor) isEqualToString:@"keep me"],
          "opening it again brings them back");

    NSMenuItem *dark = [[NSMenuItem alloc] initWithTitle:@"深色" action:@selector(setAppearanceMode:) keyEquivalent:@""];
    dark.tag = 2;
    [NSApp sendAction:dark.action to:d from:dark];
    CHECK([NSApp.appearance.name isEqual:NSAppearanceNameDarkAqua] && [ud integerForKey:@"appearance"] == 2 &&
          [d->_win.effectiveAppearance.name isEqual:NSAppearanceNameDarkAqua], "深色 applies to the window and is remembered");
    [d validateMenuItem:dark];
    CHECK(dark.state == NSControlStateValueOn, "the chosen mode is ticked");
    NSMenuItem *light = [[NSMenuItem alloc] initWithTitle:@"浅色" action:@selector(setAppearanceMode:) keyEquivalent:@""];
    light.tag = 1;
    [NSApp sendAction:light.action to:d from:light];
    CHECK([d->_win.effectiveAppearance.name isEqual:NSAppearanceNameAqua], "浅色");
    NSMenuItem *system = [[NSMenuItem alloc] initWithTitle:@"跟随系统" action:@selector(setAppearanceMode:) keyEquivalent:@""];
    system.tag = 0;
    [NSApp sendAction:system.action to:d from:system];
    CHECK(NSApp.appearance == nil && [ud integerForKey:@"appearance"] == 0, "跟随系统 clears the override");

    [d->_content closeAll];
    [NSFileManager.defaultManager removeItemAtPath:d->_content.untitledDirectory error:nil];
    for (NSString *k in @[@"lastRoot", @"recentRoots", @"sessions", @"appearance", @"NSWindow Frame FeatherMain"]) [ud removeObjectForKey:k];
}


#pragma mark Office files

static void officeFiles(NSString *dir) {
    NSWindow *w; ContentController *t = offscreenController(&w);
    __block NSUInteger asked = 0;
    __block NSModalResponse answer = NSAlertSecondButtonReturn;
    t.alertHandler = ^NSModalResponse(NSAlert *a) { asked++; return answer; };
    t.autoSaveMode = AutoSaveAfterDelay;
    t.autoSaveDelay = 0.05;
    NSString *xp = [dir stringByAppendingPathComponent:@"book.xlsx"];
    [XLFixture() writeToFile:xp atomically:YES];
    setxattr(xp.fileSystemRepresentation, "com.example.feather-test", "tag", 3, 0, 0);
    [t openPath:xp preview:NO focus:NO];
    SpreadsheetPreview *sp = findView(t.view, SpreadsheetPreview.class);
    CHECK(sp && !t.editor && sp.workbook.sheets.count == 2, "an .xlsx opens in the spreadsheet view");
    CHECK([t.statusText containsString:@"Excel workbook"], "status: %s", t.statusText.UTF8String);
    SheetGrid *g = sp.grid;
    g.frame = NSMakeRect(0, 0, 900, 500);
    NSBitmapImageRep *rep = [g bitmapImageRepForCachingDisplayInRect:g.bounds];
    [g cacheDisplayInRect:g.bounds toBitmapImageRep:rep];
    NSRect a1 = [g rectForRow:0 col:0];
    CGFloat px = rep.pixelsWide / g.bounds.size.width;                              // Retina: 2 pixels per point
    NSColor *fill = [[rep colorAtX:(NSInteger)((NSMinX(a1) + 4) * px) y:(NSInteger)((NSMinY(a1) + 3) * px)] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    CGFloat digit = [@"0" sizeWithAttributes:@{NSFontAttributeName: [g fontFor:[sp.workbook.sheets[0] styleAt:1 col:1]]}].width;
    CHECK(digit <= 7.2 * g.zoom && digit > 6 * g.zoom, "the stand-in for Calibri has Excel's 7 px digit, so column widths hold the same text (%.2f)", digit);
    CHECK(fill.blueComponent > 0.6 && fill.redComponent < 0.4, "the header cell is drawn with its fill (%.2f %.2f %.2f)", fill.redComponent, fill.greenComponent, fill.blueComponent);
    if (getenv("FV_SHOT")) [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(getenv("FV_SHOT")) atomically:YES];

    [g selectRow:1 col:1 extend:NO];
    CHECK([sp setText:@"99" row:1 col:1] && t.dirtyCount == 1, "an edit marks the tab unsaved");
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
    XLWorkbook *onDisk = [[XLWorkbook alloc] initWithData:[NSData dataWithContentsOfFile:xp] error:NULL];
    CHECK([[onDisk.sheets[0] displayAt:1 col:1 colour:NULL] isEqual:@"1,234.50"], "auto-save never writes a workbook");
    [sp undo:nil];
    CHECK(t.dirtyCount == 0 && [[sp.workbook.sheets[0] displayAt:1 col:1 colour:NULL] isEqual:@"1,234.50"], "undo restores the cell and the clean state");
    [sp redo:nil];
    CHECK(![sp setText:@"x" row:1 col:3] && t.dirtyCount == 1, "a read-only cell refuses the edit");
    asked = 0; answer = NSAlertSecondButtonReturn;
    CHECK(![t closeActive] && asked == 1, "closing with unsaved cells asks");
    CHECK([t save] && t.dirtyCount == 0, "⌘S saves the workbook");
    onDisk = [[XLWorkbook alloc] initWithData:[NSData dataWithContentsOfFile:xp] error:NULL];
    char xv[8] = {0};
    CHECK([[onDisk.sheets[0] displayAt:1 col:1 colour:NULL] isEqual:@"99.00"] && getxattr(xp.fileSystemRepresentation, "com.example.feather-test", xv, sizeof xv, 0, 0) == 3,
          "the saved file has the edit and keeps its extended attributes");
    [sp setText:@"7" row:2 col:1];                                               // dirty again, then into the background
    [t openPath:mkfile(dir, @"other.txt", @"x\n") preview:NO focus:NO];
    [t selectTabAtIndex:0];
    CHECK(findView(t.view, SpreadsheetPreview.class) == sp, "switching tabs keeps an edited workbook's view");
    sp.grid.pasteboard = [NSPasteboard pasteboardWithUniqueName];
    [sp.grid selectRow:0 col:0 extend:NO]; [sp.grid selectRow:1 col:1 extend:YES];
    [sp.grid copy:nil];
    CHECK([[sp.grid.pasteboard stringForType:NSPasteboardTypeString] isEqualToString:@"Name\tAmount\nBold part\t99.00\n"], "copy gives tab-separated text: %s",
          [sp.grid.pasteboard stringForType:NSPasteboardTypeString].UTF8String);
    CHECK([t findInActive:@"between" backward:NO] == NO && [t findInActive:@"part" backward:NO] && sp.grid.row == 1 && sp.grid.col == 0, "find selects the matching cell");
    answer = NSAlertThirdButtonReturn;
    [t closeAll];

    // Word: the system's Office renderer, shown read-only.
    NSString *dp = [dir stringByAppendingPathComponent:@"doc.docx"];
    NSAttributedString *as = [[NSAttributedString alloc] initWithString:@"Hello from a Word file"];
    [[as dataFromRange:NSMakeRange(0, as.length) documentAttributes:@{NSDocumentTypeDocumentAttribute: NSOfficeOpenXMLTextDocumentType} error:nil] writeToFile:dp atomically:YES];
    [t openPath:dp preview:NO focus:NO];
    DocumentPreview *dv = findView(t.view, DocumentPreview.class);
    CHECK(dv && !t.editor, "a .docx opens in the document view");
    spinUntil(^BOOL { return dv.loaded; }, 20);
    __block id body = nil;
    [dv evaluate:@"document.body.innerText" done:^(id r) { body = r ?: @""; }];
    spinUntil(^BOOL { return body != nil; }, 5);
    CHECK(dv.loaded && [body containsString:@"Hello from a Word file"], "the document is rendered: %s", [body description].UTF8String);
    CHECK([t.statusText containsString:@"read-only"] && t.dirtyCount == 0, "read-only status: %s", t.statusText.UTF8String);
    [t closeAll];
}

#pragma mark Data safety

static void dataSafety(NSString *dir) {
    // Backspace / Delete past the 32 KB drawing limit of a line remove one character, not the hidden text.
    NSString *lp = [dir stringByAppendingPathComponent:@"longline.txt"];
    NSMutableString *lng = [NSMutableString string];
    for (int i = 0; i < 40000; i++) [lng appendString:i % 7 ? @"a" : @"é"];
    [lng appendString:@"\nend\n"];
    [lng writeToFile:lp atomically:YES encoding:NSUTF8StringEncoding error:nil];
    TextEditorView *ed = openEditor(lp);
    NSUInteger len = ed->_buf.length, e0 = [ed->_buf lineEnd:0];
    [ed moveCaretTo:e0 extend:NO];
    [ed doCommandBySelector:@selector(deleteBackward:)];
    CHECK(ed->_buf.length == len - 1 && ed->_caret == e0 - 1, "Backspace at the end of a 40 000-char line deletes one character (%lu bytes gone)", (unsigned long)(len - ed->_buf.length));
    [ed undo:nil];
    [ed moveCaretTo:35000 extend:NO];
    while (([ed->_buf byteAt:ed->_caret] & 0xC0) == 0x80) [ed moveCaretTo:ed->_caret + 1 extend:NO];
    [ed doCommandBySelector:@selector(deleteForward:)];
    CHECK(ed->_buf.length == len - 1 || ed->_buf.length == len - 2, "Delete in the hidden part deletes one character (%lu bytes gone)", (unsigned long)(len - ed->_buf.length));
    [ed undo:nil];
    NSUInteger at = 35002;
    while ([ed->_buf byteAt:at] != 0xC3) at++;                          // on an "é"
    [ed moveCaretTo:at + 2 extend:NO];
    [ed doCommandBySelector:@selector(deleteBackward:)];
    CHECK(ed->_buf.length == len - 2 && ed->_caret == at, "a two-byte character there is deleted whole");
    [ed undo:nil];
    [ed moveCaretTo:at extend:NO];
    [ed doCommandBySelector:@selector(moveRight:)];
    CHECK(ed->_caret == at + 2, "moving right in the hidden part steps one character");

    // Input: press-and-hold accents, multi-line Tab / Shift-Tab, line endings, the remembered column.
    NSString *ip = [dir stringByAppendingPathComponent:@"input.txt"];
    [@"cafe\none\ntwo\nthree\n" writeToFile:ip atomically:YES encoding:NSUTF8StringEncoding error:nil];
    ed = openEditor(ip);
    [ed moveCaretTo:4 extend:NO];
    [ed insertText:@"é" replacementRange:NSMakeRange(3, 1)];                 // the accent popup replaces the "e"
    CHECK([text(ed) hasPrefix:@"café\n"] && ed->_caret == 5, "an accent from the press-and-hold popup replaces the letter: %s", text(ed).UTF8String);
    [ed moveCaretTo:[ed->_buf lineStart:1] extend:NO];
    [ed moveCaretTo:[ed->_buf lineStart:3] + 2 extend:YES];
    [ed doCommandBySelector:@selector(insertTab:)];
    CHECK([text(ed) isEqualToString:@"café\n    one\n    two\n    three\n"], "Tab indents every selected line: %s", text(ed).UTF8String);
    CHECK([ed->_buf lineForOffset:ed.selection.location] == 1 && [ed->_buf lineForOffset:NSMaxRange(ed.selection)] == 3, "and they stay selected");
    [ed doCommandBySelector:@selector(insertBacktab:)];
    CHECK([text(ed) isEqualToString:@"café\none\ntwo\nthree\n"], "Shift-Tab outdents them: %s", text(ed).UTF8String);
    [ed undo:nil];
    [ed undo:nil];
    CHECK([text(ed) isEqualToString:@"café\none\ntwo\nthree\n"], "each is one undo step");
    [ed moveCaretTo:[ed->_buf lineEnd:3] extend:NO];
    [ed doCommandBySelector:@selector(moveToBeginningOfLine:)];
    [ed doCommandBySelector:@selector(moveUp:)];
    CHECK(ed->_caret == [ed->_buf lineStart:2], "after Home, Up stays in the first column (at %lu)", (unsigned long)ed->_caret);
    [cc closeAll];
    NSString *crp = [dir stringByAppendingPathComponent:@"crlf-in.txt"];
    [@"a\r\nb\r\n" writeToFile:crp atomically:YES encoding:NSUTF8StringEncoding error:nil];
    ed = openEditor(crp);
    [ed insertText:@"x\ny\n" replacementRange:NSMakeRange(NSNotFound, 0)];      // e.g. dictation
    CHECK([text(ed) isEqualToString:@"x\r\ny\r\na\r\nb\r\n"], "inserted text gets the file's CRLF line endings");
    [ed undo:nil];

    // Find with Unicode case folding, CJK word steps, Emacs keys.
    NSString *up = [dir stringByAppendingPathComponent:@"unicode.txt"];
    [@"Ärger und ärger\n我们今天去北京天安门\nhello world\n" writeToFile:up atomically:YES encoding:NSUTF8StringEncoding error:nil];
    ed = openEditor(up);
    [ed moveCaretTo:0 extend:NO];
    CHECK([ed findString:@"ÄRGER" backward:NO] && ed.selection.location == 0, "Unicode find, case-insensitive");
    CHECK([ed findString:@"ÄRGER" backward:NO] && ed.selection.location == 11 && [ed.selectedText isEqualToString:@"ärger"], "finds the lower-case one next (%lu)", (unsigned long)ed.selection.location);
    CHECK([ed replaceAll:@"äRGER" with:@"Wut"] == 2 && [text(ed) hasPrefix:@"Wut und Wut\n"], "Replace All with Unicode case folding: %s", text(ed).UTF8String);
    [ed undo:nil];
    NSUInteger cj = [ed->_buf lineStart:1];
    [ed moveCaretTo:cj extend:NO];
    [ed doCommandBySelector:@selector(moveWordRight:)];
    CHECK(ed->_caret > cj && ed->_caret < [ed->_buf lineEnd:1], "⌥→ in Chinese stops at a word, not the end of the line (%lu of %lu..%lu)",
          (unsigned long)ed->_caret, (unsigned long)cj, (unsigned long)[ed->_buf lineEnd:1]);
    NSRange wr = [ed wordRangeAt:cj + 3 * 5];
    CHECK(wr.location >= cj && NSMaxRange(wr) <= [ed->_buf lineEnd:1] && wr.length < [ed->_buf lineEnd:1] - cj, "double-click selects a Chinese word, not the run");
    NSUInteger h = [ed->_buf lineStart:2];
    [ed moveCaretTo:h + 5 extend:NO];
    [ed doCommandBySelector:@selector(deleteToEndOfParagraph:)];
    CHECK([text(ed) hasSuffix:@"\nhello\n"], "⌃K deletes to the end of the line: %s", text(ed).UTF8String);
    [ed doCommandBySelector:@selector(moveToBeginningOfParagraph:)];
    [ed doCommandBySelector:@selector(yank:)];
    CHECK([text(ed) hasSuffix:@"\n worldhello\n"], "⌃Y puts it back");
    [ed doCommandBySelector:@selector(transpose:)];
    CHECK([text(ed) hasSuffix:@"\n worlhdello\n"], "⌃T swaps the characters around the caret: %s", text(ed).UTF8String);
    NSRange ax = ed.accessibilitySelectedTextRange;
    CHECK(ax.location <= [ed.accessibilityValue length] && ed.accessibilityInsertionPointLineNumber == 2, "VoiceOver gets the caret line and position");
    [cc closeAll];

    // Dragging a selection below the view keeps scrolling while the mouse stays there.
    NSString *dp = [dir stringByAppendingPathComponent:@"drag.txt"];
    NSMutableString *dl = [NSMutableString string];
    for (int i = 0; i < 400; i++) [dl appendFormat:@"line %d\n", i];
    [dl writeToFile:dp atomically:YES encoding:NSUTF8StringEncoding error:nil];
    ed = openEditor(dp);
    ed.frame = NSMakeRect(0, 0, 600, 300);
    [ed moveCaretTo:0 extend:NO];
    ed->_dragPoint = NSMakePoint(100, 400);
    [ed dragTo:ed->_dragPoint];
    CGFloat y0 = ed.scrollY;
    for (int i = 0; i < 5; i++) [ed dragTo:ed->_dragPoint];               // what the timer does while the button is held
    CHECK(ed.scrollY > y0 && ed->_caret > 0 && ed->_anchor == 0, "selection drag below the view scrolls on (%.0f → %.0f)", y0, ed.scrollY);
    [ed->_dragScroll invalidate]; ed->_dragScroll = nil;
    [cc closeAll];

    // The undo limit: after 2000+ edits, undoing all the way back must not claim the file is saved.
    [ed moveCaretTo:0 extend:NO];
    for (int i = 0; i < 2005; i++) { [ed insertText:@"z" replacementRange:NSMakeRange(NSNotFound, 0)]; ed->_coalesceBroken = YES; }
    while (ed->_undo.count) [ed undo:nil];
    CHECK(ed.isDirty && [text(ed) hasPrefix:@"zzzzz"], "undoing past the limit still shows unsaved changes");
    while (ed->_redo.count) [ed redo:nil];
    [cc closeAll];

    // Replace All keeps the caret on the same text, never inside a character.
    NSString *rp = [dir stringByAppendingPathComponent:@"caret.txt"];
    [@"a中b\nxyz\n" writeToFile:rp atomically:YES encoding:NSUTF8StringEncoding error:nil];
    ed = openEditor(rp);
    [ed moveCaretTo:4 extend:NO];                                     // before "b"
    [ed replaceAll:@"a" with:@"aa"];
    CHECK(ed->_caret == 5 && [ed->_buf byteAt:ed->_caret] == 'b', "caret follows Replace All (at %lu)", (unsigned long)ed->_caret);
    [ed undo:nil];
    [ed moveCaretTo:5 extend:NO];                                     // end of line 1
    [ed replaceAll:@"中" with:@"x"];
    CHECK(ed->_caret == 3, "a shorter replacement moves the caret back (at %lu)", (unsigned long)ed->_caret);
    [ed undo:nil];

    // Replace All and its undo stay fast with many matches (each edit used to rewrite the piece and line lists).
    NSString *bp = [dir stringByAppendingPathComponent:@"many.txt"];
    NSMutableString *many = [NSMutableString string];
    for (int i = 0; i < 100000; i++) [many appendString:@"foo bar\n"];
    [many writeToFile:bp atomically:YES encoding:NSUTF8StringEncoding error:nil];
    ed = openEditor(bp);
    CFAbsoluteTime r0 = CFAbsoluteTimeGetCurrent();
    NSUInteger rn = [ed replaceAll:@"foo" with:@"x"];
    double rt = CFAbsoluteTimeGetCurrent() - r0;
    CHECK(rn == 100000 && ed->_buf.length == 100000 * 6 && [text(ed) hasPrefix:@"x bar\nx bar\n"], "Replace All of 100 000 matches");
    r0 = CFAbsoluteTimeGetCurrent();
    [ed undo:nil];
    double ut = CFAbsoluteTimeGetCurrent() - r0;
    CHECK([text(ed) isEqualToString:many] && !ed.isDirty, "its undo restores the text");
    r0 = CFAbsoluteTimeGetCurrent();
    [ed redo:nil];
    double dt = CFAbsoluteTimeGetCurrent() - r0;
    CHECK(ed->_buf.length == 100000 * 6 && ed->_buf.lineCount == 100001, "redo");
    printf("   replace all 100 000 matches: %.2f s, undo %.2f s, redo %.2f s\n", rt, ut, dt);
    CHECK(rt < 1 && ut < 1 && dt < 1, "Replace All, undo and redo each take under a second");
    [ed undo:nil];

    // Read-only files are not overwritten by ⌘S or auto-save.
    NSString *ro = [dir stringByAppendingPathComponent:@"readonly.txt"];
    [@"locked\n" writeToFile:ro atomically:YES encoding:NSUTF8StringEncoding error:nil];
    chmod(ro.fileSystemRepresentation, 0444);
    ed = openEditor(ro);
    [ed insertText:@"changed " replacementRange:NSMakeRange(NSNotFound, 0)];
    NSString *err = nil;
    CHECK(![ed save:&err] && err.length && [fileText(ro, NSUTF8StringEncoding) isEqualToString:@"locked\n"],
          "saving a read-only file fails and leaves it alone (%s)", err.UTF8String);
    cc.autoSaveMode = AutoSaveOnFocusChange;
    CHECK(![cc flushAutoSave] && [fileText(ro, NSUTF8StringEncoding) isEqualToString:@"locked\n"] && [cc.statusText containsString:@"read-only"],
          "auto-save skips it and says why: %s", cc.statusText.UTF8String);
    cc.autoSaveMode = AutoSaveOff;
    [ed undo:nil];
    chmod(ro.fileSystemRepresentation, 0644);

    // Saving a draft over a file that is open in another tab.
    NSWindow *w; ContentController *t = offscreenController(&w);
    t.untitledDirectory = [dir stringByAppendingPathComponent:@"untitled-ds"];
    t.workspaceRoot = dir;
    __block NSUInteger asked = 0;
    __block NSModalResponse answer = NSAlertSecondButtonReturn;
    t.alertHandler = ^NSModalResponse(NSAlert *a) { asked++; return answer; };
    NSString *target = [dir stringByAppendingPathComponent:@"target.txt"];
    [@"old\n" writeToFile:target atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [t openPath:target preview:NO focus:YES];
    [t.editor insertText:@"unsaved " replacementRange:NSMakeRange(NSNotFound, 0)];
    [t newUntitledDocument];
    [t.editor insertText:@"draft\n" replacementRange:NSMakeRange(NSNotFound, 0)];
    t.savePathHandler = ^NSString *(NSString *name, NSString *folder) { return target; };
    CHECK(![t save] && asked == 1 && t.activeIsUntitled && [fileText(target, NSUTF8StringEncoding) isEqualToString:@"old\n"],
          "it asks first when that tab has unsaved changes, and Cancel writes nothing");
    answer = NSAlertFirstButtonReturn;
    CHECK([t save] && [fileText(target, NSUTF8StringEncoding) isEqualToString:@"draft\n"], "Replace saves the draft there");
    NSUInteger same = 0;
    for (NSString *p in t.openPaths) if ([p isEqualToString:target]) same++;
    CHECK(same == 1 && t.tabCount == 1 && [text(t.editor) isEqualToString:@"draft\n"], "and leaves one tab for the file (%lu)", (unsigned long)same);

    // A draft that contains a NUL byte comes back as text, not hex.
    [t newUntitledDocument];
    [t.editor insertText:[NSString stringWithCharacters:(unichar[]){'a', 0, 'b'} length:3] replacementRange:NSMakeRange(NSNotFound, 0)];
    [t backupUntitled];
    NSDictionary *session = t.sessionState;
    [t closeAllWithoutAsking];
    [t restoreSession:session];
    [t selectTabAtIndex:-1];
    CHECK(t.activeIsUntitled && t.editor && t.editor.contentLength == 3, "a draft with a NUL byte restores as text");

    // Drafts no session mentions (a crash before the session was written) come back as tabs.
    NSString *lost = [t.untitledDirectory stringByAppendingPathComponent:@"lost.txt"];
    NSString *empty = [t.untitledDirectory stringByAppendingPathComponent:@"empty.txt"];
    [@"recovered text" writeToFile:lost atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [NSData.data writeToFile:empty atomically:YES];
    NSUInteger before = t.tabCount;
    [t adoptUntitledBackups:@[lost, empty]];
    [t selectTabAtIndex:-1];
    CHECK(t.tabCount == before + 1 && t.activeIsUntitled && [text(t.editor) isEqualToString:@"recovered text"] &&
          ![NSFileManager.defaultManager fileExistsAtPath:empty], "a lost draft is reopened, an empty one removed");
    [t closeAllWithoutAsking];
    [NSFileManager.defaultManager removeItemAtPath:t.untitledDirectory error:nil];
}

static void appLifecycle(NSString *dir) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    for (NSString *k in @[@"lastRoot", @"recentRoots", @"sessions"]) [ud removeObjectForKey:k];
    NSString *ws = [dir stringByAppendingPathComponent:@"ws_life"];
    [NSFileManager.defaultManager createDirectoryAtPath:ws withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *f = mkfile(ws, @"notes.txt", @"hello\n");
    AppDelegate *d = [AppDelegate new];
    [d applicationWillFinishLaunching:[NSNotification notificationWithName:NSApplicationWillFinishLaunchingNotification object:NSApp]];
    d->_content.untitledDirectory = [dir stringByAppendingPathComponent:@"untitled-life"];
    d->_content.autoSaveMode = AutoSaveOff;
    __block NSModalResponse answer = NSAlertThirdButtonReturn;
    __block NSUInteger asked = 0;
    d->_content.alertHandler = ^NSModalResponse(NSAlert *al) { asked++; return answer; };
    [d openRoot:ws];
    [d openFile:f];
    [d->_content.editor insertText:@"x" replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK([d windowShouldClose:d->_win] && asked == 1 && d->_content.tabCount == 0, "closing the window asks once");
    [d mainWindowWillReappear];
    CHECK(d->_content.tabCount == 1 && [d->_content.currentPath isEqualToString:f], "reopening the window brings its tabs back");
    [d->_content.editor insertText:@"y" replacementRange:NSMakeRange(NSNotFound, 0)];
    asked = 0;
    answer = NSAlertSecondButtonReturn;
    CHECK([d applicationShouldTerminate:NSApp] == NSTerminateCancel && asked == 1, "⌘Q after reopening still asks about unsaved changes");
    [d->_content.editor undo:nil];

    // Word wrap is ⌥⌘Z: a plain ⌥ letter is how many keyboards type characters (⌥Z is Ω, or ż in Polish).
    NSMenuItem *wrapItem = nil;
    for (NSMenuItem *top in NSApp.mainMenu.itemArray) for (NSMenuItem *i in top.submenu.itemArray) if (i.action == @selector(toggleWordWrap:)) wrapItem = i;
    CHECK(wrapItem && (wrapItem.keyEquivalentModifierMask & NSEventModifierFlagCommand), "Word Wrap uses ⌘ (%lx)", (unsigned long)wrapItem.keyEquivalentModifierMask);

    // ⌘W in another window closes that window, not a tab behind it.
    NSWindow *other = [[NSWindow alloc] initWithContentRect:NSMakeRect(-20000, -20000, 200, 100) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                    backing:NSBackingStoreBuffered defer:YES];
    other.releasedWhenClosed = NO;
    [other orderBack:nil];
    d->_keyWindowOverride = other;
    NSMenuItem *closeItem = [[NSMenuItem alloc] initWithTitle:@"Close Tab" action:@selector(closeTab:) keyEquivalent:@"w"];
    [NSApp sendAction:@selector(closeTab:) to:d from:closeItem];
    CHECK(!other.isVisible && d->_content.tabCount == 1, "⌘W with Settings in front closes Settings and keeps the tab");
    d->_keyWindowOverride = nil;
    [d->_content closeAllWithoutAsking];
    CHECK([d validateMenuItem:closeItem], "⌘W is enabled in an empty main window (it closes the window)");

    // Save All carries on past a draft whose save panel was cancelled.
    NSString *g = mkfile(ws, @"g.txt", @"g\n");
    [d->_content newUntitledDocument];
    [d->_content.editor insertText:@"draft" replacementRange:NSMakeRange(NSNotFound, 0)];
    [d openFile:g];
    [d->_content.editor insertText:@"edit " replacementRange:NSMakeRange(NSNotFound, 0)];
    d->_content.savePathHandler = ^NSString *(NSString *name, NSString *folder) { return nil; };
    CHECK(![d->_content saveAll] && [fileText(g, NSUTF8StringEncoding) isEqualToString:@"edit g\n"], "Save All saves the file even after the draft's panel is cancelled");
    d->_content.savePathHandler = nil;
    answer = NSAlertThirdButtonReturn;
    [d->_content closeAll];

    // Reopen Closed Tab doesn't bring back a tab from the previous workspace.
    NSString *ws2 = [dir stringByAppendingPathComponent:@"ws_life2"];
    [NSFileManager.defaultManager createDirectoryAtPath:ws2 withIntermediateDirectories:YES attributes:nil error:nil];
    [d openFile:f];
    [d->_content closeActive];
    [d openRoot:ws2];
    CHECK(![d->_content reopenClosed] && d->_content.tabCount == 0, "Reopen Closed Tab stays within the workspace");
    [d openRoot:ws];

    // The workspace is watched: a file created outside the app shows up in the tree without a manual refresh.
    __block NSUInteger fired = 0;
    FileWatcher *fw = [[FileWatcher alloc] initWithRoot:ws onChange:^{ fired++; }];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
    mkfile(ws, @"from-outside.txt", @"new\n");
    CHECK(fw && spinUntil(^BOOL { return fired > 0; }, 5), "the watcher notices a new file");
    [fw stop];
    CHECK(![FileWatcher pathIsInteresting:[ws stringByAppendingPathComponent:@"node_modules/x/y.js"] root:ws] &&
          ![FileWatcher pathIsInteresting:[ws stringByAppendingPathComponent:@".git/index"] root:ws] &&
          ![FileWatcher pathIsInteresting:[ws stringByAppendingPathComponent:@".feather-Ab12Cd"] root:ws] &&
          [FileWatcher pathIsInteresting:[ws stringByAppendingPathComponent:@"src/a.c"] root:ws], "changes in skipped folders and our own temp files are ignored");
    __block BOOL refreshed = NO;
    d->_tree.onRefreshed = ^{ refreshed = YES; };
    mkfile(ws, @"bg-new.txt", @"x\n");
    [d->_tree refreshInBackground];
    BOOL listed = NO;
    if (spinUntil(^BOOL { return refreshed; }, 5))
        for (NSInteger r = 0; r < d->_outline.numberOfRows; r++) if ([[(FileNode *)[d->_outline itemAtRow:r] name] isEqual:@"bg-new.txt"]) listed = YES;
    CHECK(listed, "a background refresh adds it to the tree");
    d->_tree.onRefreshed = nil;

    // Dropping onto the window: files open as tabs, a folder becomes the workspace.
    [d->_content closeAllWithoutAsking];
    NSString *dropped = mkfile(ws, @"dropped.md", @"# hi\n");
    CHECK([d openDroppedURLs:@[[NSURL fileURLWithPath:dropped]]] && [d->_content.currentPath isEqualToString:dropped], "a dropped file opens");
    NSString *ws3 = [dir stringByAppendingPathComponent:@"ws_dropped"];
    [NSFileManager.defaultManager createDirectoryAtPath:ws3 withIntermediateDirectories:YES attributes:nil error:nil];
    CHECK([d openDroppedURLs:@[[NSURL fileURLWithPath:ws3]]] && [d->_tree.rootPath isEqualToString:ws3], "a dropped folder becomes the workspace");
    CHECK(![d openDroppedURLs:@[[NSURL URLWithString:@"https://example.com"]]], "a web link is not a drop target");
    [d openRoot:ws];

    // A workspace on a volume that is not mounted keeps its saved session.
    NSString *gone = @"/Volumes/FeatherView-not-mounted/project";
    NSMutableDictionary *all = [[ud dictionaryForKey:@"sessions"] mutableCopy];
    all[gone] = @{@"tabs": @[@{@"path": [gone stringByAppendingPathComponent:@"a.txt"], @"line": @0}], @"active": @0};
    [ud setObject:all forKey:@"sessions"];
    [ud setObject:@[ws, gone] forKey:@"recentRoots"];
    [d saveSession];
    CHECK([ud dictionaryForKey:@"sessions"][gone] != nil, "an unmounted workspace's session is kept");
    [d noteRecentRoot:ws];
    CHECK([[ud stringArrayForKey:@"recentRoots"] containsObject:gone] && ![d.recentRoots containsObject:gone],
          "it stays in the stored recent list but is not shown");
    [d->_content closeAllWithoutAsking];
    [NSFileManager.defaultManager removeItemAtPath:d->_content.untitledDirectory error:nil];
    for (NSString *k in @[@"lastRoot", @"recentRoots", @"sessions"]) [ud removeObjectForKey:k];
}

#pragma mark Search panel

static void searchPanel(NSString *dir) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    for (NSString *k in @[@"searchScope", @"searchCase", @"searchWord", @"searchRegex", @"searchFilter"]) [ud removeObjectForKey:k];
    NSString *root = [dir stringByAppendingPathComponent:@"ws_search"];
    for (NSString *sub in @[@"src", @"assets/icons", @"tests"])
        [NSFileManager.defaultManager createDirectoryAtPath:[root stringByAppendingPathComponent:sub] withIntermediateDirectories:YES attributes:nil error:nil];
    mkfile(root, @"src/app.ts", @"import logo from '../assets/logo.svg';\nconst icon = 'logo.svg';\n");
    mkfile(root, @"src/view.m", @"// draws logo.svg\nint Logo = 1;\n");
    mkfile(root, @"tests/app.test.ts", @"expect('logo.svg');\n");
    mkfile(root, @"assets/logo.svg", @"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"4\" height=\"4\"/>");
    mkfile(root, @"assets/icons/close.svg", @"<svg/>");
    mkfile(root, @"README.md", @"# demo\n");

    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 300, 700) styleMask:NSWindowStyleMaskTitled
                                                backing:NSBackingStoreBuffered defer:YES];
    SearchPanel *sp = [SearchPanel new];
    sp.view.frame = w.contentView.bounds;
    w.contentView = sp.view;
    sp.root = root;
    NSMutableArray *opened = [NSMutableArray array];
    sp.onOpen = ^(SearchHit *h, BOOL f) { [opened addObject:[NSString stringWithFormat:@"%@:%lu", h.path.lastPathComponent, (unsigned long)h.line]]; };
    sp.onOpenFile = ^(NSString *p, BOOL f) { [opened addObject:p.lastPathComponent]; };
    void (^run)(NSString *) = ^(NSString *q) { sp.query = q; [sp runNow]; spinUntil(^BOOL { return !sp.busy; }, 8); spinUntil(^BOOL { return NO; }, 0.15); };

    run(@".svg");
    CHECK(sp.nameCount == 2 && sp.contentFileCount == 3 && sp.hitCount == 4, "“.svg” finds 2 file names and 4 lines in 3 files (%lu / %lu / %lu)",
          (unsigned long)sp.nameCount, (unsigned long)sp.contentFileCount, (unsigned long)sp.hitCount);
    CHECK([sp.statusText containsString:@"2 names"] && [sp.statusText containsString:@"4 matches in 3 files"], "status: %s", sp.statusText.UTF8String);
    NSOutlineView *ov = sp.resultsView;
    CHECK(ov.numberOfRows >= 2 + 2 + 3 + 4, "sections, names, files and lines are all listed (%ld rows)", (long)ov.numberOfRows);

    run(@"*.svg");
    CHECK(sp.nameCount == 2 && sp.contentFileCount == 0, "a glob searches file names only (%lu / %lu)", (unsigned long)sp.nameCount, (unsigned long)sp.contentFileCount);
    run(@"logo");
    CHECK(sp.nameCount == 1 && sp.contentFileCount == 3, "plain words: names and contents (%lu / %lu)", (unsigned long)sp.nameCount, (unsigned long)sp.contentFileCount);

    sp.scope = SearchScopeNames;
    run(@"app");
    CHECK(sp.nameCount == 2 && sp.contentFileCount == 0, "scope 文件名 (%lu / %lu)", (unsigned long)sp.nameCount, (unsigned long)sp.contentFileCount);
    sp.scope = SearchScopeContents;
    sp.filterText = @"*.ts, !tests";
    run(@"logo");
    CHECK(sp.nameCount == 0 && sp.contentFileCount == 1 && sp.hitCount == 2, "scope 内容 + include / exclude (%lu files, %lu lines)",
          (unsigned long)sp.contentFileCount, (unsigned long)sp.hitCount);
    sp.filterText = @"";
    sp.caseSensitive = YES;
    run(@"Logo");
    CHECK(sp.contentFileCount == 1 && sp.hitCount == 1, "Aa: case-sensitive (%lu)", (unsigned long)sp.hitCount);
    sp.caseSensitive = NO;
    sp.wholeWord = YES;
    run(@"logo");
    CHECK(sp.hitCount == 5, "全词: logo.svg and Logo match, logos would not (%lu)", (unsigned long)sp.hitCount);
    sp.wholeWord = NO;
    sp.regex = YES;
    run(@"logo\\.(svg|png)'");
    CHECK(sp.hitCount == 3, ".*: regex (%lu)", (unsigned long)sp.hitCount);
    run(@"(unclosed");
    CHECK([sp.statusText containsString:@"regular expression"] && !sp.hasResults, "bad regex shown in the status: %s", sp.statusText.UTF8String);
    sp.regex = NO;
    CHECK([ud integerForKey:@"searchScope"] == SearchScopeContents && ![ud boolForKey:@"searchRegex"], "options are remembered");

    run(@"logo");
    [opened removeAllObjects];
    [sp selectNextResult:NO];
    [sp selectNextResult:NO];
    [sp selectNextResult:YES];
    CHECK(opened.count == 3 && [opened[0] isEqual:opened[2]] && ![opened[0] isEqual:opened[1]], "F4 / ⇧F4 step through the matches: %s",
          [opened componentsJoinedByString:@" "].UTF8String);
    run(@"no-such-text-anywhere");
    CHECK(!sp.hasResults && [sp.statusText containsString:@"No results"], "no results: %s", sp.statusText.UTF8String);
    run(@"");
    CHECK(!sp.hasResults && ov.numberOfRows == 0, "clearing the query clears the list");
    for (NSString *k in @[@"searchScope", @"searchCase", @"searchWord", @"searchRegex", @"searchFilter"]) [ud removeObjectForKey:k];
}

#pragma mark Syntax colours

// One letter per character: . plain k keyword s string c comment n number T type f function p property
// t tag C constant M meta H heading e emphasis S strong I inserted D deleted
static NSString *kinds(NSString *file, NSString *line) {
    static const char *K = ".kscnTfptCMHeSID";
    NSMutableString *m = [NSMutableString string];
    for (NSUInteger i = 0; i < line.length; i++) [m appendString:@"."];
    [[Highlighter highlighterForPath:file] tokenize:line emit:^(NSRange r, TokenKind k) {
        for (NSUInteger i = r.location; i < NSMaxRange(r); i++) [m replaceCharactersInRange:NSMakeRange(i, 1) withString:[NSString stringWithFormat:@"%c", K[k]]];
    }];
    return m;
}

static void syntaxColours(void) {
    struct { NSString *file, *mode; } modes[] = {
        {@"a.ts", @"code"}, {@"a.json", @"json"}, {@"a.yml", @"yaml"}, {@"Cargo.toml", @"toml"}, {@".env", @"ini"},
        {@"a.scss", @"css"}, {@"a.html", @"markup"}, {@"a.svg", @"markup"}, {@"a.vue", @"markup"}, {@"README.md", @"markdown"},
        {@"x.patch", @"diff"}, {@"Makefile", @"code"}, {@"Dockerfile.dev", @"code"}, {@".gitignore", @"ignore"}};
    for (size_t i = 0; i < sizeof modes / sizeof *modes; i++)
        CHECK([[Highlighter highlighterForPath:modes[i].file].modeName isEqual:modes[i].mode], "%s highlighted as %s",
              modes[i].file.UTF8String, modes[i].mode.UTF8String);
    CHECK([Highlighter highlighterForPath:@"notes.txt"] == nil, "plain text stays plain");

    // the old palette coloured JSON keys, values and Markdown alike: now each part has its own kind
    CHECK([kinds(@"a.json", @"\"name\": \"x\", \"n\": 1, \"ok\": true") isEqual:@"pppppp..sss..ppp..n..pppp..CCCC"], "JSON keys ≠ values");
    CHECK([kinds(@"a.yml", @"  - name: build # step") isEqual:@"..C.pppp..sssss.cccccc"], "YAML key / value / comment");
    CHECK([kinds(@"Cargo.toml", @"[deps]") isEqual:@"tttttt"] &&
          [kinds(@"Cargo.toml", @"v = { a = \"1\" }") isEqual:@"p.....p...sss.."], "TOML sections and inline tables");
    CHECK([kinds(@"a.css", @"  color: #fff; margin: 0 -4px;") isEqual:@"..ppppp..nnnn..pppppp..n.nnnn."], "CSS declarations");
    CHECK([kinds(@"a.css", @".btn:hover > a {") isEqual:@"TTTTkkkkkk...t.."], "CSS selectors");
    CHECK([kinds(@"a.html", @"<a href=\"x\">Hi &amp;</a>") isEqual:@"Mt.pppp.sssM...CCCCCMMtM"], "HTML tag / attribute / entity");
    CHECK([kinds(@"a.md", @"## Install `npm`") isEqual:@"MMHHHHHHHHHsssss"], "Markdown heading keeps its code span");
    CHECK([kinds(@"a.md", @"- see [doc](x.md) **now**") isEqual:@"C.....MfffMMccccM.MMSSSMM"], "Markdown list / link / bold");
    CHECK([kinds(@"a.md", @"my snake_case_name") isEqual:@".................."], "underscores inside words are not emphasis");
    CHECK([kinds(@"a.ts", @"const x = fetchUser(id).name; // hi") isEqual:@"kkkkk.....fffffffff.....pppp..ccccc"], "TS call / member / comment");
    CHECK([kinds(@"a.sh", @"echo $HOME ${#a} $# # c") isEqual:@"ffff.ppppp.ppppp.pp.ccc"], "shell variables vs # comments");
    CHECK([kinds(@"a.py", @"@dec  # c") isEqual:@"MMMM..ccc"], "Python decorator");
    CHECK([kinds(@"a.rs", @"fn f<'a>(s: &'a str)") isEqual:@"kk...TT......TT.TTT."], "Rust lifetimes are not strings");
    CHECK([kinds(@"x.diff", @"-gone") isEqual:@"DDDDD"] && [kinds(@"x.diff", @"+new") isEqual:@"IIII"], "diff lines");

    // red is reserved for deleted diff lines; everything else is readable on its background
    for (NSString *name in @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]) {
        [[NSAppearance appearanceNamed:name] performAsCurrentDrawingAppearance:^{
            NSColor *bg = [NSColor.textBackgroundColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            CGFloat (^lum)(NSColor *) = ^CGFloat(NSColor *c) {
                CGFloat ch[3] = {c.redComponent, c.greenComponent, c.blueComponent};
                for (int i = 0; i < 3; i++) ch[i] = ch[i] <= 0.03928 ? ch[i] / 12.92 : pow((ch[i] + 0.055) / 1.055, 2.4);
                return 0.2126 * ch[0] + 0.7152 * ch[1] + 0.0722 * ch[2];
            };
            for (TokenKind k = TokKeyword; k < TokKindCount; k++) {
                NSColor *c = [HLColor(k) colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
                CGFloat h = c.hueComponent * 360, sat = c.saturationComponent;
                BOOL reddish = sat > 0.35 && (h < 18 || h > 335);
                CHECK(reddish == (k == TokDeleted), "%s kind %d: hue %.0f° %s", name.UTF8String, k, h, k == TokDeleted ? "is red" : "is not red");
                CGFloat a = lum(c), b = lum(bg), ratio = (MAX(a, b) + 0.05) / (MIN(a, b) + 0.05);
                CHECK(ratio >= (k == TokComment ? 2.5 : 3.0), "%s kind %d contrast %.1f", name.UTF8String, k, ratio);
            }
        }];
    }
}

static void viewers(NSString *dir) {
    NSString *bin = [dir stringByAppendingPathComponent:@"blob"];
    uint8_t bytes[64] = {0x7f, 'E', 'L', 'F', 0, 1, 2};
    [[NSData dataWithBytes:bytes length:sizeof bytes] writeToFile:bin atomically:YES];
    [cc openPath:bin preview:NO focus:NO];
    CHECK(cc.editor == nil, "binary file not opened as text");
    NSUInteger before = cc.tabCount;
    [cc openPath:dir preview:NO focus:NO];
    [cc openPath:@"" preview:NO focus:NO];
    [cc openPath:nil preview:NO focus:NO];
    CHECK(cc.tabCount == before, "directory / empty path does not open a tab");

    NSString *img = @"/System/Library/Desktop Pictures/iMac Blue.heic";
    if (![NSFileManager.defaultManager fileExistsAtPath:img]) return;
    [cc openPath:img preview:NO focus:NO];
    ImagePreviewView *iv = nil;
    for (NSView *v in cc.view.subviews) if ([v isKindOfClass:ImagePreviewView.class]) iv = (ImagePreviewView *)v;
    CHECK(iv != nil, "image viewer chosen");
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (iv && iv.decodedSize.width == 0 && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    CGFloat s = win.backingScaleFactor ?: 2, limit = MAX(iv.bounds.size.width, iv.bounds.size.height) * s;
    CHECK(iv.decodedSize.width > 0 && iv.decodedSize.width <= limit, "downsampled decode: %.0fx%.0f (limit %.0f)",
          iv.decodedSize.width, iv.decodedSize.height, limit);
    CHECK([iv.info containsString:@"6016"], "reports original size: %s", iv.info.UTF8String);
}

#pragma mark Word wrap

// The incrementally maintained row table must equal a fresh measurement of every line.
static BOOL wrapTableConsistent(TextEditorView *ed, NSString **why) {
    [ed ensureWrap];
    if (!ed->_wrapActive) return YES;
    NSUInteger n = ed->_buf.lineCount;
    if (ed->_wrapLines != n) { *why = [NSString stringWithFormat:@"table has %lu lines, buffer %lu", ed->_wrapLines, n]; return NO; }
    uint64_t acc = 0;
    for (NSUInteger L = 0; L < n; L++) {
        if (ed->_rowStart[L] != acc) {
            *why = [NSString stringWithFormat:@"line %lu starts at row %llu, want %llu", L, ed->_rowStart[L], acc];
            return NO;
        }
        WrapRows r = [ed rowsOf:[ed displayString:L]];
        free(r.starts);
        acc += r.count;
    }
    if (ed->_rowStart[n] != acc) { *why = @"total row count"; return NO; }
    return YES;
}

static void wordWrap(NSString *dir) {
    NSWindow *w; ContentController *t = offscreenController(&w);
    NSMutableString *src = [NSMutableString stringWithString:@"short line\n"];
    for (int i = 0; i < 40; i++) [src appendFormat:@"word%d ", i];
    [src appendString:@"\n\tindented: "];
    for (int i = 0; i < 30; i++) [src appendString:@"alpha beta "];
    [src appendString:@"\nhttps://example.com/a/very/long/path/that/keeps/going/and/going/without/any/spaces/at/all/in/it/index.html\n"];
    for (int i = 0; i < 60; i++) [src appendString:@"中文自动换行测试，"];
    [src appendString:@"结束。\n"];
    [src appendString:[@"" stringByPaddingToLength:500 withString:@"x" startingAtIndex:0]];
    [src appendString:@"\n"];
    for (int i = 0; i < 200; i++) [src appendFormat:@"line %d\n", i];
    t.wordWrap = NO;
    [t openPath:mkfile(dir, @"wrap.txt", src) preview:NO focus:NO];
    TextEditorView *ed = t.editor;
    CHECK(!ed.wrapsLines && ed.rowCount == ed->_buf.lineCount, "wrap off: one row per line");
    NSBitmapImageRep *rep = [ed bitmapImageRepForCachingDisplayInRect:ed.bounds];
    [ed cacheDisplayInRect:ed.bounds toBitmapImageRep:rep];                 // widest line is learnt while drawing
    CHECK(ed.maxScrollX > 0, "long lines scroll sideways without wrap");

    t.wordWrap = YES;
    CHECK(ed.wordWrap && ed.wrapsLines, "wrap on");
    NSUInteger rows = ed.rowCount;
    CHECK(rows > ed->_buf.lineCount + 10, "long lines take several rows (%lu rows, %lu lines)",
          (unsigned long)rows, (unsigned long)ed->_buf.lineCount);
    CHECK(ed.maxScrollX == 0 && ed.scrollX == 0, "no sideways scrolling while wrapping");
    NSString *why = nil;
    CHECK(wrapTableConsistent(ed, &why), "row table after build: %s", why.UTF8String);

    // rows fit the width, cover the line, and break at sensible places
    CGFloat width = ed->_wrapWidth;
    for (NSUInteger L = 0; L < 6; L++) {
        NSString *s = [ed lineString:L];
        WrapRows r = [ed rowsOf:s];
        for (NSUInteger k = 0; k < r.count; k++) {
            NSUInteger a = k ? r.starts[k] : 0, b = k + 1 < r.count ? r.starts[k + 1] : s.length;
            CHECK(b > a, "row %lu of line %lu is empty", (unsigned long)k, (unsigned long)L);
            CTLineRef line = [ed createLine:s range:NSMakeRange(a, b - a)];
            CGFloat lw = CTLineGetTypographicBounds(line, NULL, NULL, NULL) - CTLineGetTrailingWhitespaceWidth(line);
            CFRelease(line);
            CHECK((k ? r.indent : 0) + lw <= width + 0.5, "line %lu row %lu is %.1f wide (max %.1f)", (unsigned long)L, (unsigned long)k, lw, width);
            if (!k) continue;
            unichar c = [s characterAtIndex:a];
            CHECK(c != 0xFF0C && c != 0x3002, "line %lu row %lu starts with closing punctuation", (unsigned long)L, (unsigned long)k);
            if (L == 1) CHECK([s characterAtIndex:a - 1] == ' ', "words break after a space (row %lu)", (unsigned long)k);
            if (L == 3) CHECK([s characterAtIndex:a - 1] == '/', "URLs break after a slash");
        }
        if (L == 2) CHECK(r.count > 1 && r.indent > 0, "continuation rows of an indented line are indented");
        if (L == 5) {
            NSUInteger cols = (NSUInteger)floor(width / ed->_charWidth + 0.01);
            CHECK(r.count == (500 + cols - 1) / cols, "a word without breaks fills whole rows (%lu rows, %lu cols)",
                  (unsigned long)r.count, (unsigned long)cols);
        }
        free(r.starts);
    }

    // nothing is drawn between the wrap edge and the minimap
    ed.scrollY = 0;
    [ed cacheDisplayInRect:ed.bounds toBitmapImageRep:rep];
    CGFloat scale = rep.pixelsWide / ed.bounds.size.width;
    CGFloat bandA = ed.textOriginX + width + 2, bandB = NSMinX(ed.minimapRect) - 2;
    NSColor *bg = [rep colorAtX:(NSInteger)(bandA * scale) y:2];
    NSUInteger ink = 0;
    for (NSInteger y = 0; y < rep.pixelsHigh; y += 2)
        for (NSInteger x = (NSInteger)(bandA * scale); x < (NSInteger)(bandB * scale); x++) {
            NSColor *c = [rep colorAtX:x y:y];
            if (fabs(c.redComponent - bg.redComponent) + fabs(c.greenComponent - bg.greenComponent) + fabs(c.blueComponent - bg.blueComponent) > 0.1) ink++;
        }
    CHECK(bandB > bandA && ink == 0, "no text past the wrap edge (%lu inked pixels)", (unsigned long)ink);

    // caret: up / down walk rows, End goes to the end of the logical line
    NSUInteger l1 = [ed->_buf lineStart:1], row1 = [ed firstRowOfLine:1];
    [ed moveCaretTo:l1 extend:NO];
    [ed doCommandBySelector:@selector(moveDown:)];
    CHECK([ed->_buf lineForOffset:ed->_caret] == 1 && [ed rowOfOffset:ed->_caret x:NULL] == row1 + 1, "moveDown goes one row down inside the line");
    [ed doCommandBySelector:@selector(moveToEndOfLine:)];
    CHECK(ed->_caret == [ed->_buf lineEnd:1], "End goes to the end of the logical line");
    [ed doCommandBySelector:@selector(moveUp:)];
    CHECK([ed->_buf lineForOffset:ed->_caret] == 1, "moveUp from the last row stays in the line");

    // clicks
    ed.scrollY = 0;
    CGFloat lh = ed->_lineHeight;
    NSUInteger off = [ed offsetAtPoint:NSMakePoint(ed.textOriginX + 3 * ed->_charWidth + 1, 4 + (row1 + 1) * lh + lh / 2)];
    CHECK([ed rowOfOffset:off x:NULL] == row1 + 1, "a click lands on the wrapped row it hits");
    off = [ed offsetAtPoint:NSMakePoint(ed.textOriginX + width - 2, 4 + row1 * lh + lh / 2)];
    CHECK([ed rowOfOffset:off x:NULL] == row1 && [ed->_buf lineForOffset:off] == 1, "a click right of a wrapped row stays on that row");

    // edits keep the table equal to a full rebuild
    [ed moveCaretTo:[ed->_buf lineEnd:1] extend:NO];
    for (int i = 0; i < 120; i++) [ed insertText:(i % 9 == 8 ? @" " : @"y") replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK(wrapTableConsistent(ed, &why), "after typing: %s", why.UTF8String);
    [ed doCommandBySelector:@selector(insertNewline:)];
    [ed insertText:@"inserted line" replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK(wrapTableConsistent(ed, &why), "after a newline: %s", why.UTF8String);
    [ed moveCaretTo:[ed->_buf lineStart:2] extend:NO];
    [ed moveCaretTo:[ed->_buf lineStart:6] extend:YES];
    [ed doCommandBySelector:@selector(deleteBackward:)];
    CHECK(wrapTableConsistent(ed, &why), "after deleting lines: %s", why.UTF8String);
    [ed undo:nil];
    CHECK(wrapTableConsistent(ed, &why), "after undo: %s", why.UTF8String);
    [ed redo:nil];
    [ed undo:nil];
    NSUInteger hits = [ed replaceAll:@" " with:@"  "];
    CHECK(hits > 64 && wrapTableConsistent(ed, &why), "after replace all (%lu): %s", (unsigned long)hits, why.UTF8String);
    [ed undo:nil];
    CHECK(wrapTableConsistent(ed, &why), "after undoing replace all: %s", why.UTF8String);

    // IME text on the line wraps with it
    [ed moveCaretTo:[ed->_buf lineEnd:0] extend:NO];
    NSString *ime = [@"" stringByPaddingToLength:120 withString:@"输入法组合文字" startingAtIndex:0];
    [ed setMarkedText:ime selectedRange:NSMakeRange(0, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK([ed firstRowOfLine:1] - [ed firstRowOfLine:0] > 1 && wrapTableConsistent(ed, &why), "composition wraps: %s", why.UTF8String);
    [ed cacheDisplayInRect:ed.bounds toBitmapImageRep:rep];
    [ed insertText:@"好" replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK([ed firstRowOfLine:1] - [ed firstRowOfLine:0] == 1 && wrapTableConsistent(ed, &why), "committed: %s", why.UTF8String);

    // resizing re-wraps and keeps the line at the top
    [ed scrollToLine:4.5];
    CGFloat top = ed.topVisibleLine;
    NSSize size = ed.frame.size;
    rows = ed.rowCount;
    [ed setFrameSize:NSMakeSize(size.width / 2, size.height)];
    CHECK(ed.rowCount > rows && wrapTableConsistent(ed, &why), "narrower: more rows (%lu → %lu) %s",
          (unsigned long)rows, (unsigned long)ed.rowCount, why.UTF8String);
    CHECK(fabs(ed.topVisibleLine - top) < 0.01, "narrowing keeps the top line (%.2f → %.2f)", top, ed.topVisibleLine);
    [ed setFrameSize:size];
    CHECK(ed.rowCount == rows && fabs(ed.topVisibleLine - top) < 0.01, "widening restores (%.2f)", ed.topVisibleLine);
    ed.fontSize = 18;
    CHECK(fabs(ed.topVisibleLine - top) < 0.01 && wrapTableConsistent(ed, &why), "font size keeps the top line (%.2f) %s", ed.topVisibleLine, why.UTF8String);
    ed.fontSize = 13;
    t.showsMinimap = NO;
    CHECK(ed.rowCount < rows && fabs(ed.topVisibleLine - top) < 0.01, "hiding the minimap widens the text");
    t.showsMinimap = YES;
    [ed setFrameSize:NSMakeSize(150, size.height)];
    CHECK(!ed.wrapsLines, "too narrow to wrap: falls back to scrolling");
    [ed setFrameSize:size];
    t.wordWrap = NO;
    CHECK(!ed.wrapsLines && ed.rowCount == ed->_buf.lineCount && fabs(ed.topVisibleLine - top) < 0.01, "wrap off again keeps the line (%.2f)", ed.topVisibleLine);
    t.wordWrap = YES;

    // cost on a 100k-line file: building the table, typing, scrolling frames
    NSMutableString *big = [NSMutableString string];
    for (int i = 0; i < 100000; i++)
        [big appendFormat:i % 10 ? @"    if (value_%d > %d) { call(\"str\", %d); } // comment\n"
                                 : @"    // %d a much longer comment line that will certainly wrap at the normal editor width, with words and more words\n", i, i, i];
    [t openPath:mkfile(dir, @"bigwrap.c", big) preview:NO focus:NO];
    ed = t.editor;
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    ed.wordWrap = NO; ed.wordWrap = YES;
    double build = (CFAbsoluteTimeGetCurrent() - t0) * 1000;
    CHECK(ed.wrapsLines && ed.rowCount > 110000, "big file wraps (%lu rows)", (unsigned long)ed.rowCount);
    [ed moveCaretTo:[ed->_buf lineEnd:50000] extend:NO];
    t0 = CFAbsoluteTimeGetCurrent();
    for (int i = 0; i < 200; i++) [ed insertText:@"z" replacementRange:NSMakeRange(NSNotFound, 0)];
    double typing = (CFAbsoluteTimeGetCurrent() - t0) * 1000 / 200;
    NSBitmapImageRep *r2 = [ed bitmapImageRepForCachingDisplayInRect:ed.bounds];
    t0 = CFAbsoluteTimeGetCurrent();
    for (int f = 0; f < 100; f++) { ed.scrollY = ed.maxScrollY * f / 100.0; [ed cacheDisplayInRect:ed.bounds toBitmapImageRep:r2]; }
    double frame = (CFAbsoluteTimeGetCurrent() - t0) * 1000 / 100;
    printf("   wrap on a 100k-line file: build %.1f ms, keystroke %.3f ms, frame %.2f ms\n", build, typing, frame);
    CHECK(build < 250 && typing < 2 && frame < 16, "wrap is fast enough");
    CHECK(wrapTableConsistent(ed, &why), "big file table: %s", why.UTF8String);

    // very large files don't wrap, and say so
    NSMutableData *many = [NSMutableData dataWithLength:1000001];
    memset(many.mutableBytes, '\n', many.length);
    NSString *mp = [dir stringByAppendingPathComponent:@"many.txt"];
    [many writeToFile:mp atomically:NO];
    [t openPath:mp preview:NO focus:NO];
    CHECK(t.editor.wordWrap && !t.editor.wrapsLines && [t.editor.statusText containsString:@"not wrapped"], "a million lines: no wrap, noted in the status bar");
    [t closeAllWithoutAsking];
}

#pragma mark Localization

static NSArray<NSString *> *menuTitles(NSMenu *m) {
    NSMutableArray *t = [NSMutableArray array];
    for (NSMenuItem *i in m.itemArray) if (i.submenu.title.length) [t addObject:i.submenu.title];   // top-level items show the submenu's title
    return t;
}

// English is the development language; zh-Hans comes from Resources/zh-Hans.lproj (scripts/l10n.py checks coverage).
static void localization(NSString *dir) {
    NSString *p = mkfile(dir, @"l10n.txt", @"hello\n");
    CHECK([FTLP(1, @"%lu file", @"%lu files") isEqual:@"%lu file"] && [FTLP(2, @"%lu file", @"%lu files") isEqual:@"%lu files"], "English plural forms");

    AppDelegate *en = [AppDelegate new];
    [en buildMenu];
    NSArray *top = menuTitles(NSApp.mainMenu);
    CHECK([top containsObject:@"File"] && [top containsObject:@"Edit"] && [top containsObject:@"View"] && [top containsObject:@"Tabs"],
          "English menus: %s", [top componentsJoinedByString:@", "].UTF8String);
    NSWindow *w; ContentController *t = offscreenController(&w);
    [t openPath:p preview:NO focus:NO];
    CHECK([t.statusText hasPrefix:@"Ln 1, Col 1"], "English status bar: %s", t.statusText.UTF8String);
    [t closeAllWithoutAsking];

    FTSetLocalizationFolder(@"Resources/zh-Hans.lproj");
    CHECK([FTL(@"Save All") isEqual:@"全部保存"] && [FTL(@"Not in the table") isEqual:@"Not in the table"], "zh-Hans table loaded, unknown keys fall back to English");
    CHECK([FTLP(1, @"%lu file", @"%lu files") isEqual:FTLP(2, @"%lu file", @"%lu files")], "Chinese has one form for any count");
    AppDelegate *zh = [AppDelegate new];
    [zh buildMenu];
    top = menuTitles(NSApp.mainMenu);
    CHECK([top containsObject:@"文件"] && [top containsObject:@"编辑"] && [top containsObject:@"显示"] && [top containsObject:@"标签页"],
          "Chinese menus: %s", [top componentsJoinedByString:@", "].UTF8String);
    NSMenu *view = nil;
    for (NSMenuItem *i in NSApp.mainMenu.itemArray) if ([i.submenu.title isEqual:@"显示"]) view = i.submenu;
    BOOL plus = NO;
    for (NSMenuItem *i in view.itemArray) if ([i.keyEquivalent isEqual:@"+"]) plus = YES;
    CHECK(plus, "the hidden ⌘+ item is still added to the localized View menu");
    t = offscreenController(&w);
    [t openPath:p preview:NO focus:NO];
    CHECK([t.statusText hasPrefix:@"行 1，列 1"], "Chinese status bar: %s", t.statusText.UTF8String);
    NSString *err = nil;
    JSONParse([@"{\"a\" 1}" dataUsingEncoding:NSUTF8StringEncoding], &err);
    CHECK([err isEqual:@"第 1 行第 6 列：属性名后面缺少 :"], "parser messages are translated too: %s", err.UTF8String);
    [t closeAllWithoutAsking];
    FTSetLocalizationFolder(nil);
    [en buildMenu];
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 600) styleMask:NSWindowStyleMaskTitled
                                            backing:NSBackingStoreBuffered defer:YES];
        cc = [ContentController new];
        cc.alertHandler = ^NSModalResponse(NSAlert *a) { return NSAlertThirdButtonReturn; };   // never block on a modal
        cc.view.frame = win.contentView.bounds;
        win.contentView = cc.view;
        editing(dir);
        crlfAndEncodings(dir);
        replaceAndJump(dir);
        tree(dir);
        treeMultiSelect(dir);
        tabs(dir);
        markdownPreview(dir);
        minimap(dir);
        wordWrap(dir);
        readmeIssues(dir);
        imageViewer(dir);
        svgAndTypeScript(dir);
        pdfViewer(dir);
        zoomOtherViews(dir);
        defaultApps(dir);
        openFromFinder(dir);
        multiSelectActions(dir);
        htmlPreviewAndAutosave(dir);
        autosave(dir);
        layoutAndWorkspaces(dir);
        viewers(dir);
        syntaxColours();
        searchPanel(dir);
        untitledDocuments(dir);
        dataViews(dir);
        binaryViews(dir);
        hiddenFileSettings(dir);
        recentAndAppearance(dir);
        officeFiles(dir);
        dataSafety(dir);
        appLifecycle(dir);
        localization(dir);
        [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
    }
    if (failures) { printf("%d editor failure(s)\n", failures); return 1; }
    printf("all editor tests passed\n");
    return 0;
}
