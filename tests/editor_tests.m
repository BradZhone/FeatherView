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
#import <PDFKit/PDFKit.h>
#include <sys/stat.h>

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while (0)

static NSString *text(TextEditorView *ed) {
    return [[NSString alloc] initWithData:[ed->_buf dataInRange:NSMakeRange(0, ed->_buf.length)] encoding:NSUTF8StringEncoding];
}
static NSString *fileText(NSString *p, NSStringEncoding enc) {
    return [NSString stringWithContentsOfFile:p encoding:enc error:nil];
}

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
    CHECK([kw isEqual:NSColor.systemPinkColor], "python keyword highlighted");
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
    spinUntil(^BOOL { return [t.statusText containsString:@"不存在"]; }, 2);
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

static void pdfViewer(NSString *dir) {
    NSWindow *w; ContentController *t = offscreenController(&w);
    NSString *pdf = [dir stringByAppendingPathComponent:@"doc.pdf"];
    writePDF(pdf, @[@"Alpha one", @"Bravo two", @"Charlie three needle"], nil);
    [t openPath:pdf preview:NO focus:NO];
    PDFPreview *pv = t.activePDF;
    CHECK(pv && pv.pageCount == 3, "PDF opens in the PDF viewer (%lu pages)", (unsigned long)pv.pageCount);
    CHECK([t.statusText containsString:@"第 1 / 3 页"], "status shows the page: %s", t.statusText.UTF8String);
    CHECK(pv.toolsView.superview != nil, "PDF tools in the status bar");
    [pv nextPage];
    CHECK(pv.currentPage == 1, "next page");
    [t goToPage:2];
    CHECK(pv.currentPage == 2 && [t.statusText containsString:@"第 3 / 3 页"], "go to page 3: %s", t.statusText.UTF8String);
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
    while (q.count) { NSView *v = q[0]; [q removeObjectAtIndex:0]; if ([v isKindOfClass:NSButton.class] && [[(NSButton *)v title] isEqualToString:@"全部替换"]) replaceAll = (id)v; [q addObjectsFromArray:v.subviews]; }
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
    CHECK(t.editor.fontSize == f0 + 2 && [t.statusText containsString:@"字号"], "⌘+ grows the editor font (%.0f → %.0f)", f0, t.editor.fontSize);
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
    spinUntil(^BOOL { return [t.statusText containsString:@"外部修改"]; }, 3);
    CHECK([t.statusText containsString:@"外部修改"] && t.editor.isDirty, "never overwrites an externally changed file: %s", t.statusText.UTF8String);
    CHECK([fileText(a, NSUTF8StringEncoding) isEqualToString:@"changed elsewhere\n"] && asked == 0, "disk content kept, still no prompt");

    t.autoSaveMode = AutoSaveOnFocusChange;
    [t openPath:b preview:NO focus:NO];                           // leaving a: tried again, still refused
    [t.editor insertText:@"3" replacementRange:NSMakeRange(NSNotFound, 0)];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
    CHECK(t.editor.isDirty, "focus-change mode does not save while typing");
    chmod(ad.fileSystemRepresentation, 0555);
    [t openPath:c preview:NO focus:NO];
    [t selectTabAtIndex:1];
    CHECK([t.statusText containsString:@"自动保存失败"] && t.editor.isDirty && asked == 0, "failed auto-save is reported in the status bar: %s", t.statusText.UTF8String);
    chmod(ad.fileSystemRepresentation, 0755);
    [t openPath:c preview:NO focus:NO];
    CHECK([fileText(b, NSUTF8StringEncoding) isEqualToString:@"3b\n"], "switching tabs saves the one you leave");
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
    for (NSMenuItem *i in d->_rootPopup.menu.itemArray) {
        if ([i.representedObject isEqual:r1]) ws1 = i;
        if ([i.representedObject isEqual:r2]) ws2 = i;
    }
    CHECK(ws1 && ws2 && ws2.state == NSControlStateValueOn && ws1.state == NSControlStateValueOff, "dropdown lists workspaces, current checked");
    [NSApp sendAction:ws1.action to:d from:ws1];
    CHECK([d->_tree.rootPath isEqualToString:r1] && [d->_content.currentPath isEqualToString:f1],
          "clicking a workspace switches back and restores its tabs");
    for (NSString *k in @[@"lastRoot", @"recentRoots", @"sessions", @"NSWindow Frame FeatherMain"])
        [NSUserDefaults.standardUserDefaults removeObjectForKey:k];
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
        tabs(dir);
        markdownPreview(dir);
        minimap(dir);
        readmeIssues(dir);
        imageViewer(dir);
        pdfViewer(dir);
        zoomOtherViews(dir);
        htmlPreviewAndAutosave(dir);
        autosave(dir);
        layoutAndWorkspaces(dir);
        viewers(dir);
        [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
    }
    if (failures) { printf("%d editor failure(s)\n", failures); return 1; }
    printf("all editor tests passed\n");
    return 0;
}
